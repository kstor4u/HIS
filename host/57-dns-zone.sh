###############################################################################
#           FICHIER DE ZONE DNS (enregistrements à publier chez l'hébergeur)   #
###############################################################################

# Produit, d'après les services réellement actifs (keep/cleanup = présents ; skip/remove =
# absents), la liste des enregistrements à créer pour DOMAIN. Relancé à chaque installation et à
# la demande : ./install.sh --run dns_zone_generate. L'installateur ne modifie JAMAIS ta zone :
# il écrit un fichier BIND (sans SOA ni NS, gérés par ton hébergeur DNS) et te montre ce qui a
# changé depuis la dernière version (à ajouter / à supprimer).
#
# Sorties dans DNS_ZONE_DIR :
#   <DOMAIN>.zone          noms relatifs à DOMAIN (zone dédiée ou déléguée)
#   <DOMAIN>.parent.zone   (si DNS_ZONE_PARENT est défini) les mêmes enregistrements, à ajouter
#                          dans la zone parente : ex. DOMAIN=machin.ipassed.fr, parent=ipassed.fr

# Adresse publique à publier : DNS_ZONE_IP, sinon détectée ; vide si introuvable.
dns_zone_public_ip() {

    if [[ -n "${DNS_ZONE_IP:-}" ]]; then
        printf '%s' "$DNS_ZONE_IP"
        return 0
    fi
    curl -s4 --connect-timeout 4 --max-time 6 https://api.ipify.org 2>/dev/null || true
}

# Noms (relatifs à DOMAIN) servis par l'hôte : exactement ceux que SWAG met dans le certificat.
# Chacun DOIT être résolu publiquement, sinon Let's Encrypt refuse tout le certificat.
dns_zone_hosts() {

    [[ "$ENABLE_SWAG" == "true" ]] || return 0

    echo "@"
    subdomain_hosts zone
    return 0
}

# Enregistrement DKIM du CT MAIL, mis sur une ligne (valeur seule) ; vide si indisponible.
dns_zone_dkim_value() {

    local out
    [[ "$ENABLE_MAIL" == "true" ]] && pct status "$MAIL_ID" >/dev/null 2>&1 || return 0
    out="$(mail_dkim 2>/dev/null || true)"
    [[ -n "$out" ]] || return 0

    printf '%s' "$out" | tr '\n\t' '  ' | sed -E 's/^.*TXT[[:space:]]+//; s/;[^"]*$//; s/[[:space:]]+$//'
}

# Lignes « nom|type|valeur » (noms relatifs à DOMAIN), dans l'ordre d'écriture.
dns_zone_records() {

    local ip="$1" h spf dkim
    local -A seen=()

    while IFS= read -r h; do
        [[ -n "$h" && -z "${seen[$h]+x}" ]] || continue
        seen["$h"]=1
        echo "${h}|A|${ip:-@PUBLIC_IP@}"
    done < <(dns_zone_hosts)

    if [[ "$ENABLE_MAIL" == "true" ]]; then
        spf='"v=spf1 mx ~all"'
        [[ -z "${MAIL_RELAY_HOST:-}" ]] || spf='"v=spf1 mx include:@SPF_DU_RELAIS@ ~all"'
        echo "@|MX|10 ${MAIL_SUBDOMAIN}.${DOMAIN}."
        echo "@|TXT|${spf}"
        echo "_dmarc|TXT|\"v=DMARC1; p=none; rua=mailto:postmaster@${DOMAIN}\""
        dkim="$(dns_zone_dkim_value)"
        echo "mail._domainkey|TXT|${dkim:-@DKIM_A_COMPLETER@}"
    fi
}

# dns_zone_render <fichier> <origine> <suffixe-relatif ou ""> : écrit la zone
dns_zone_render() {

    local file="$1" origin="$2" suffix="$3" ip="$4" rec name type value rel
    {
        echo "; Zone DNS générée par l'installateur ${SCRIPT_VERSION} pour ${DOMAIN} le $(date '+%F %T')."
        echo "; Services pris en compte : SWAG=${ENABLE_SWAG} DOCKER=${ENABLE_DOCKER} MAIL=${ENABLE_MAIL} NODE=${ENABLE_NODE} MONITOR=${ENABLE_MONITOR}"
        echo "; Format BIND sans SOA ni NS (gérés par ton hébergeur DNS). Les valeurs @...@ sont à compléter."
        [[ -n "$suffix" ]] && echo "; À AJOUTER dans la zone ${origin} (les noms incluent déjà « ${suffix} »)."
        echo "\$ORIGIN ${origin}."
        echo "\$TTL ${DNS_ZONE_TTL:-3600}"
        while IFS='|' read -r name type value; do
            [[ -n "$name" ]] || continue
            if [[ -n "$suffix" ]]; then
                if [[ "$name" == "@" ]]; then rel="$suffix"; else rel="${name}.${suffix}"; fi
            else
                rel="$name"
            fi
            printf '%-32s IN %-4s %s\n' "$rel" "$type" "$value"
        done < <(dns_zone_records "$ip")
        if [[ "$ENABLE_MAIL" == "true" ]]; then
            echo "; PTR (DNS inverse) de ${ip:-<IP publique>} -> ${MAIL_SUBDOMAIN}.${DOMAIN} : à demander à ton fournisseur d'accès."
        fi
    } > "$file"
}

# Écrit les fichiers de zone et affiche ce qui a changé depuis la version précédente.
dns_zone_generate() {

    local dir="${DNS_ZONE_DIR:-/var/lib/homelab/dns-zone}" ip file prev suffix="" parent_file
    local old new added removed

    [[ "${ENABLE_DNS_ZONE:-true}" == "true" ]] || return 0
    [[ -n "${DOMAIN:-}" ]] || return 0

    info "Zone DNS : génération (IP publique, DKIM)..."
    install -d -m 755 "$dir"
    file="${dir}/${DOMAIN}.zone"
    prev="${file}.prev"
    ip="$(dns_zone_public_ip)"

    [[ -f "$file" ]] && cp -f "$file" "$prev"

    dns_zone_render "$file" "$DOMAIN" "" "$ip"

    if [[ -n "${DNS_ZONE_PARENT:-}" ]]; then
        if [[ "$DOMAIN" == *".${DNS_ZONE_PARENT}" ]]; then
            suffix="${DOMAIN%".${DNS_ZONE_PARENT}"}"
            parent_file="${dir}/${DOMAIN}.parent.zone"
            dns_zone_render "$parent_file" "$DNS_ZONE_PARENT" "$suffix" "$ip"
        else
            warn "DNS_ZONE_PARENT='${DNS_ZONE_PARENT}' : DOMAIN='${DOMAIN}' n'en est pas un sous-domaine, variante parente non générée."
        fi
    fi

    info "Zone DNS : ${file}$([[ -n "$suffix" ]] && echo " et ${parent_file}")"
    [[ -n "$ip" ]] || warn "Zone DNS : IP publique introuvable (@PUBLIC_IP@ à remplacer) ; définis DNS_ZONE_IP pour la fixer."

    if [[ -f "$prev" ]]; then
        old="$(grep -v '^;' "$prev" | sort)"
        new="$(grep -v '^;' "$file" | sort)"
        added="$(comm -13 <(printf '%s\n' "$old") <(printf '%s\n' "$new") | grep -v '^\$' || true)"
        removed="$(comm -23 <(printf '%s\n' "$old") <(printf '%s\n' "$new") | grep -v '^\$' || true)"
        if [[ -z "$added$removed" ]]; then
            info "Zone DNS : aucun changement depuis la génération précédente."
        else
            echo "Zone DNS : changements depuis la génération précédente"
            [[ -z "$added" ]]   || { echo "  À AJOUTER / MODIFIER chez ton hébergeur DNS :"; printf '%s\n' "$added" | sed 's/^/    + /'; }
            [[ -z "$removed" ]] || { echo "  À SUPPRIMER (service retiré ou valeur remplacée) :"; printf '%s\n' "$removed" | sed 's/^/    - /'; }
        fi
    fi
}
