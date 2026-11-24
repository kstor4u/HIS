###############################################################################
#          FICHIER DE RÉPONSES JSON : CRÉATION, FUSION, DOCUMENTATION         #
###############################################################################

# Ce module est chargé AVANT la journalisation : "--update-answers", "--init-answers" et "--describe" s'exécutent donc
# sans toucher au système (ni root, ni Proxmox requis, seulement jq) et s'arrêtent aussitôt. Ici, pas de log/info/die :
# echo et exit.
#
#   ./install.sh --init-answers [fichier]     crée le fichier de réponses JSON (groupé par section) et la documentation
#                                             proxmox-homelab-variables.md à côté, puis s'arrête.
#   ./install.sh --update-answers [fichier]   crée le fichier s'il n'existe pas ; sinon fusionne : tes valeurs sont CONSERVÉES,
#                                             les variables apparues depuis sont ajoutées (valeur null = défaut du script) et
#                                             listées dans la clé "_nouveau". L'ancien fichier est gardé en .bak-<date>.
#   ./install.sh --describe [VARIABLE]        décrit une variable (ou toutes celles qui commencent par ce nom).
#   ./install.sh                              (lancement normal) : même vérification ; s'il y a des variables nouvelles, le
#                                             fichier est mis à jour, et l'installation S'ARRÊTE seulement si l'une d'elles est
#                                             « requise ». Contourner : ./install.sh --skip-answers-check ou ANSWERS_CHECK=false.
#
# Format du fichier (voir proxmox-homelab-variables.md) : un objet JSON dont les groupes (obligatoire, services, reseau...) ne
# servent qu'à ranger : seul le NOM de la variable compte (il doit être unique dans tout le fichier). null (ou absent) = valeur
# par défaut du script. Les clés qui commencent par « _ » sont ignorées (_version, _note, _nouveau).
#
# Le schéma des variables (groupe, type, défaut, description) est dans core/04-answers-schema.sh : source unique du fichier neuf,
# de la documentation, de --describe et de la fusion.

ANSWERS_US=$'\x1f'      # séparateur interne des flux envoyés à jq

# Définitions jq communes : conversion d'une valeur texte vers son type JSON d'après le schéma.
ANSWERS_JQ_DEFS='
def conv($t; $v):
    if $t == "bool" then (if $v == "true" then true elif $v == "false" then false else $v end)
    elif $t == "int" then (if ($v | test("^[0-9]+$")) then ($v | tonumber) else $v end)
    else $v end;
'

# Feuilles (variable -> valeur) d'un fichier de réponses : NOM NUL VALEUR NUL ... ; null ignoré ; liste de textes = noms
# séparés par des espaces (ex. plusieurs sous-domaines) ; les clés « _xxx » sont des métadonnées.
ANSWERS_JQ_LEAVES='
del(.sites) | [ .. | objects | to_entries[] | select((.key | startswith("_") | not) and ((.value | type) != "object") and (.value != null)) ]
| .[]
| .key, "\u0000",
  ( .value | if type == "array"
             then (if all(.[]; type == "string" or type == "number" or type == "boolean")
                   then map(tostring) | join(" ")
                   else error("liste non scalaire pour " + (. | tostring)) end)
             else tostring end ),
  "\u0000"
'

# Variables que le fichier de réponses n'a pas le droit de fixer (protection de l'environnement du script).
answers_forbidden_name() {
    case "$1" in
        PATH | IFS | HOME | SHELL | USER | LOGNAME | PWD | OLDPWD | ENV | UID | EUID | PPID | SHELLOPTS | BASHOPTS | \
        PS1 | PS2 | PS4 | PROMPT_COMMAND | BASH_* | LD_* | LC_* | LANG | LANGUAGE | TMPDIR | TERM) return 0 ;;
    esac
    return 1
}

# jq est lu partout (réponses, secrets). Installé automatiquement si on est root (paquet Debian standard).
answers_require_jq() {
    command -v jq > /dev/null 2>&1 && return 0
    if [[ "$(id -u)" == "0" ]] && command -v apt-get > /dev/null 2>&1; then
        echo "jq est nécessaire pour lire le fichier de réponses (JSON) : installation..." >&2
        DEBIAN_FRONTEND=noninteractive apt-get install -y jq > /dev/null 2>&1 \
            || { DEBIAN_FRONTEND=noninteractive apt-get update > /dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y jq > /dev/null 2>&1; }
        command -v jq > /dev/null 2>&1 && return 0
    fi
    echo "ERREUR : jq est requis pour le fichier de réponses (JSON). Installe-le : sudo apt install jq   puis relance." >&2
    return 1
}

# ------------------------------------------------------------------ schéma
declare -gA SCHEMA_GROUP=() SCHEMA_TYPE=() SCHEMA_REQ=() SCHEMA_INIT=() SCHEMA_DEF=() SCHEMA_DESC=() SCHEMA_GROUP_TITLE=()
declare -ga SCHEMA_ORDER=() SCHEMA_GROUPS=()
SCHEMA_LOADED=false

answers_schema_load() {
    [[ "$SCHEMA_LOADED" != "true" ]] || return 0
    local kind a b c d e f g
    while IFS='^' read -r kind a b c d e f g; do
        case "$kind" in
            G) SCHEMA_GROUPS+=("$a"); SCHEMA_GROUP_TITLE["$a"]="$b" ;;
            V) SCHEMA_ORDER+=("$b")
               SCHEMA_GROUP["$b"]="$a"; SCHEMA_TYPE["$b"]="$c"; SCHEMA_REQ["$b"]="$d"
               SCHEMA_INIT["$b"]="$e"; SCHEMA_DEF["$b"]="$f"; SCHEMA_DESC["$b"]="$g" ;;
        esac
    done < <(answers_schema_text)
    SCHEMA_LOADED=true
}

# Flux du schéma pour jq : groupe, nom, type, « est null ? » (1/0), valeur  (séparés par ANSWERS_US)
answers_schema_stream() {   # $1 = template (valeur init des requises) ; sinon null partout
    local n
    for n in "${SCHEMA_ORDER[@]}"; do
        if [[ "${SCHEMA_REQ[$n]}" == "1" ]]; then
            printf '%s\x1f%s\x1f%s\x1f0\x1f%s\n' "${SCHEMA_GROUP[$n]}" "$n" "${SCHEMA_TYPE[$n]}" "${SCHEMA_INIT[$n]}"
        else
            printf '%s\x1f%s\x1f%s\x1f1\x1f\n' "${SCHEMA_GROUP[$n]}" "$n" "${SCHEMA_TYPE[$n]}"
        fi
    done
}

ANSWERS_NOTE="null = valeur par défaut du script. Documentation des variables : proxmox-homelab-variables.md ou ./install.sh --describe [VARIABLE]. Peut contenir des mots de passe : droits 600, jamais dans git."

# Fichier neuf : variables requises avec leur valeur d'exemple, toutes les autres à null.
answers_template_json() {
    answers_schema_load
    answers_schema_stream | jq -R -n --arg ver "$SCRIPT_VERSION" --arg note "$ANSWERS_NOTE" "$ANSWERS_JQ_DEFS"'
        reduce (inputs | split("\u001f")) as $r ({"_version": $ver, "_note": $note, "sites": {}};
            .[$r[0]][$r[1]] = (if $r[3] == "1" then null else conv($r[2]; $r[4]) end))'
}

# ------------------------------------------------------------------ fusion
ANSWERS_NEW_VARS=()
ANSWERS_NEW_ACTIVE=()      # nouvelles variables « requises » (à regarder en priorité)
ANSWERS_CUSTOM_COUNT=0

# answers_merge_json <existant.json> [nonew]  -> JSON fusionné sur la sortie standard ; remplit ANSWERS_NEW_VARS.
# Tes valeurs sont conservées telles quelles (type compris) ; les variables du schéma absentes sont ajoutées (requise : valeur
# d'exemple, sinon null) ; ce que le schéma ne connaît pas va dans le groupe « personnalise ».
answers_merge_json() {

    local old="$1" nonew="${2:-}" k n
    local -A seen=()
    local -a unknown=()
    ANSWERS_NEW_VARS=(); ANSWERS_NEW_ACTIVE=(); ANSWERS_CUSTOM_COUNT=0
    answers_schema_load

    while IFS= read -r -d '' k; do seen["$k"]=1; done < <(
        jq -j 'del(.sites) | [ .. | objects | to_entries[] | select((.key | startswith("_") | not) and ((.value | type) != "object")) | .key ] | .[] | ., "\u0000"' "$old")

    for n in "${SCHEMA_ORDER[@]}"; do
        [[ -n "${seen[$n]+x}" ]] && continue
        ANSWERS_NEW_VARS+=("$n")
        [[ "${SCHEMA_REQ[$n]}" == "1" ]] && ANSWERS_NEW_ACTIVE+=("$n")
    done
    for k in "${!seen[@]}"; do [[ -n "${SCHEMA_GROUP[$k]+x}" ]] || unknown+=("$k"); done
    ANSWERS_CUSTOM_COUNT=${#unknown[@]}

    local newjson="[]"
    if [[ -z "$nonew" && ${#ANSWERS_NEW_VARS[@]} -gt 0 ]]; then
        newjson="$(printf '%s\n' "${ANSWERS_NEW_VARS[@]}" | jq -R . | jq -s .)"
    fi

    answers_schema_stream | jq -R -n --arg ver "$SCRIPT_VERSION" --arg note "$ANSWERS_NOTE" --slurpfile u "$old" \
        --argjson nouveau "$newjson" "$ANSWERS_JQ_DEFS"'
        ($u[0] | del(.sites) | [ .. | objects | to_entries[] | select((.key | startswith("_") | not) and ((.value | type) != "object")) ] | from_entries) as $user
        | [inputs | split("\u001f")] as $sch
        | ($sch | map(.[1])) as $known
        | {"_version": $ver, "_note": $note}
          + (if ($nouveau | length) > 0 then {"_nouveau": $nouveau} else {} end)
          + {"sites": ($u[0].sites // {})}
          + (reduce $sch[] as $r ({};
                .[$r[0]][$r[1]] = (if ($user | has($r[1])) then $user[$r[1]]
                                   elif $r[3] == "0" then conv($r[2]; $r[4])
                                   else null end)))
          + (($user | with_entries(select(.key as $k | ($known | index($k)) == null))) as $x
             | if ($x | length) > 0 then {"personnalise": $x} else {} end)'
}

# ------------------------------------------------------------------ documentation
answers_doc_text() {
    answers_schema_load
    cat <<EOF_DOC_HEAD
# Variables du fichier de réponses (installateur v${SCRIPT_VERSION})

Fichier généré par \`./install.sh --init-answers\` / \`--update-answers\` : ne pas l'éditer, il est régénéré.
Une variable en particulier : \`./install.sh --describe NOM\` (ou le début d'un nom, ex. \`NEXTCLOUD_\`).

## Format du fichier \`proxmox-homelab-answers.json\`

- Un objet JSON. Les **groupes** (\`obligatoire\`, \`services\`, \`reseau\`...) ne servent qu'à ranger : seul le **nom de la
  variable** compte ; il doit rester unique dans tout le fichier. Tu peux déplacer une variable d'un groupe à l'autre.
- **\`null\` (ou clé absente) = valeur par défaut du script.** Pour changer une valeur, remplace \`null\` par la valeur voulue.
- Valeurs : texte (\`"abc"\`), \`true\` / \`false\`, nombre (\`8192\`). Un texte vide \`""\` est une vraie valeur (par ex. mot de passe
  vide = généré ou demandé), différente de \`null\`.
- Plusieurs noms pour une variable qui l'accepte (sous-domaines...) : soit un texte avec espaces (\`"cloud nc"\`), soit une liste
  (\`["cloud", "nc"]\`).
- Les variables de type \`ref\` peuvent contenir \`\${AUTRE_VARIABLE}\` (ex. \`"\${DATA_MOUNT}/SHARED"\`).
- Les clés qui commencent par \`_\` sont ignorées : \`_version\`, \`_note\`, \`_nouveau\` (variables ajoutées par la dernière mise à
  jour). Tes variables inconnues du modèle sont rangées dans le groupe \`personnalise\` (appliquées, avec un avertissement).
- Le fichier peut contenir des mots de passe : droits 600, jamais dans git. Les mots de passe GÉNÉRÉS par le script sont gardés
  à part dans \`proxmox-homelab-secrets.json\`.

## Services à états (\`ENABLE_SWAG\`, \`ENABLE_DOCKER\`, \`ENABLE_FILES\`, \`ENABLE_XMRIG\`, \`ENABLE_WIREGUARD\`, \`ENABLE_NODE\`, \`ENABLE_MAIL\`...)

| Valeur | Effet |
|---|---|
| \`"keep"\` | installe si absent, conserve s'il existe |
| \`"run"\` | existe déjà : applique SEULEMENT les paramètres (rien créé, supprimé, téléchargé ni installé) |
| \`"cleanup"\` | supprime puis recrée à neuf (repasser en \`keep\` ensuite !) |
| \`"remove"\` | supprime et n'installe pas |
| \`"skip"\` | ne touche à rien |
| \`""\` | installe si absent ; s'il existe, demande |

Les états s'appliquent à un invité entier (VM/CT) : pour Nextcloud, c'est \`ENABLE_DOCKER\` (VM 103).

## Plusieurs domaines (section \`sites\`)

Section facultative, à la racine du JSON (hors des groupes). Absente : un seul site, \`DOMAIN\`. Chaque site a ses dossiers dans
DATA (\`<racine>/SHARED\` et \`<racine>/apps\`) et son groupe Unix ; l'infrastructure (VM Docker, SWAG, mail, DNS...) est commune.

\`\`\`json
"sites": {
  "ipassed.fr": { "racine": null },
  "autre.org":  { "racine": "/mnt/data/autre.org", "services": ["nextcloud", "mail", "samba"] }
}
\`\`\`

| Clé | Effet |
|---|---|
| \`racine\` | dossier du site ; \`null\` = \`\${DATA_MOUNT}/<domaine>\` (valable aussi pour le site principal \`DOMAIN\`) |
| \`services\` | parmi \`nextcloud syncin immich jellyfin homeassistant arr mail samba node\` : dossiers créés (défaut d'un site secondaire : \`samba\`) |
| \`groupe\`, \`gid\` | groupe Unix du site (défaut \`fs_<domaine>\`, GID libre à partir de 2001) ; le site principal garde \`fileshare\` / 2000 |

Commandes : \`./install.sh --sites-status\` (état), \`./install.sh --site-add domaine.tld [svc1,svc2] [/racine]\` (ajoute au fichier
et crée les dossiers). Sauvegardes (restic, export USB, source de tirage, fichiers témoins) : tous les sites sont couverts.
Phase actuelle : dossiers, groupes et sauvegardes ; les services par domaine (SWAG, DNS, applications, mail) viennent ensuite.
EOF_DOC_HEAD
    local g n t desc def
    for g in "${SCHEMA_GROUPS[@]}"; do
        printf '\n## %s : %s\n\n' "$g" "${SCHEMA_GROUP_TITLE[$g]}"
        for n in "${SCHEMA_ORDER[@]}"; do
            [[ "${SCHEMA_GROUP[$n]}" == "$g" ]] || continue
            t="${SCHEMA_TYPE[$n]}"; desc="${SCHEMA_DESC[$n]}"; def="${SCHEMA_DEF[$n]}"
            case "$t" in str) t="texte" ;; bool) t="true/false" ;; int) t="nombre" ;; ref) t="chemin" ;; esac
            [[ "${SCHEMA_REQ[$n]}" == "1" ]] && t+=", à renseigner"
            printf -- '- **%s** (%s) : %s' "$n" "$t" "$desc"
            [[ "$desc" == *[Dd]éfaut* || -z "$def" ]] || printf ' Défaut : `%s`.' "$def"
            printf '\n'
        done
    done
}

answers_doc_write() {   # <fichier de réponses> -> écrit proxmox-homelab-variables.md dans le même dossier
    local dir doc
    dir="$(dirname -- "$1")"; doc="${dir}/proxmox-homelab-variables.md"
    answers_doc_text > "$doc" && echo "Documentation des variables : ${doc}"
}

answers_describe() {   # [NOM|début de nom|motif]
    answers_schema_load
    local pat="${1:-}" g n t d found=0
    if [[ -z "$pat" ]]; then
        for g in "${SCHEMA_GROUPS[@]}"; do
            echo; echo "[${g}] ${SCHEMA_GROUP_TITLE[$g]}"
            for n in "${SCHEMA_ORDER[@]}"; do [[ "${SCHEMA_GROUP[$n]}" == "$g" ]] && printf '%s ' "$n"; done | fold -s -w 100 | sed 's/^/    /'
            echo
        done
        echo; echo "Détail d'une variable : ./install.sh --describe NOM   (ou le début du nom, ex. NEXTCLOUD_)"
        return 0
    fi
    for n in "${SCHEMA_ORDER[@]}"; do
        # shellcheck disable=SC2053
        if [[ "${n^^}" == "${pat^^}"* || "${n^^}" == ${pat^^} ]]; then
            found=1
            t="${SCHEMA_TYPE[$n]}"; d="${SCHEMA_DEF[$n]}"
            printf '\n%s  [%s, groupe %s%s]\n' "$n" "$t" "${SCHEMA_GROUP[$n]}" "$([[ "${SCHEMA_REQ[$n]}" == "1" ]] && echo ', à renseigner')"
            printf '    défaut : %s\n' "${d:-(vide)}"
            printf '%s\n' "${SCHEMA_DESC[$n]}" | fold -s -w 100 | sed 's/^/    /'
        fi
    done
    if (( found == 0 )); then echo "Aucune variable ne correspond à « ${pat} » (liste : ./install.sh --describe)." >&2; return 1; fi
}

# ------------------------------------------------------------------ création / mise à jour
# Cœur commun à --init-answers, --update-answers et à la vérification au lancement.
# $1 = fichier ; $2 = « force » pour réécrire la documentation même sans changement ; code retour :
#   0 = rien à faire/créé ; 10 = variables « requises » ajoutées (à compléter) ; 1 = erreur.
answers_update_file() {

    local file tmp bak mode rc=0 v
    file="$1"
    answers_require_jq || return 1
    answers_schema_load
    tmp="$(mktemp)"

    if [[ ! -f "$file" ]]; then
        answers_template_json > "$tmp" || { rm -f "$tmp"; echo "ERREUR : création du modèle impossible." >&2; return 1; }
        install -m 600 "$tmp" "$file"
        rm -f "$tmp"
        echo "Fichier de réponses créé : ${file} (droits 600, ${#SCHEMA_ORDER[@]} variables ; null = défaut du script)."
        answers_doc_write "$file" || true
        echo "Complète-le (au minimum DOMAIN, LE_EMAIL et les mots de passe), puis relance ./install.sh"
        return 0
    fi

    if ! jq -e 'type == "object"' "$file" > /dev/null 2>&1; then
        echo "ERREUR : ${file} n'est pas un JSON valide :" >&2
        jq . "$file" 2>&1 | head -3 | sed 's/^/    /' >&2
        rm -f "$tmp"; return 1
    fi

    if ! answers_merge_json "$file" > "$tmp"; then
        rm -f "$tmp"; echo "ERREUR : fusion impossible (voir ${file})." >&2; return 1
    fi

    if (( ${#ANSWERS_NEW_VARS[@]} == 0 )); then
        rm -f "$tmp"
        echo "Fichier de réponses à jour : aucune variable nouvelle (${file})."
        [[ "${2:-}" != "force" ]] || answers_doc_write "$file" || true
        return 0
    fi

    bak="${file}.bak-$(date +%Y%m%d-%H%M%S)"
    mode="$(stat -c %a "$file" 2> /dev/null || echo 600)"
    cp -p "$file" "$bak"
    cat "$tmp" > "$file"          # écrit dans le fichier existant : droits et propriétaire inchangés
    chmod "$mode" "$file" 2> /dev/null || true
    chmod 600 "$bak" 2> /dev/null || true
    rm -f "$tmp"
    answers_doc_write "$file" > /dev/null || true

    echo
    echo "Fichier de réponses mis à jour : ${file}"
    echo "  - tes valeurs ont été conservées ; ancien fichier : ${bak}"
    echo "  - ${#ANSWERS_NEW_VARS[@]} variable(s) ajoutée(s), listées dans la clé \"_nouveau\" ; documentation : proxmox-homelab-variables.md"
    if (( ${#ANSWERS_NEW_ACTIVE[@]} > 0 )); then
        echo "  - À RENSEIGNER en priorité (variables requises) :"
        printf '      %s\n' "${ANSWERS_NEW_ACTIVE[@]}"
        rc=10
    fi
    local -a optional=()
    for v in "${ANSWERS_NEW_VARS[@]}"; do
        [[ " ${ANSWERS_NEW_ACTIVE[*]:-} " == *" $v "* ]] || optional+=("$v")
    done
    if (( ${#optional[@]} > 0 )); then
        echo "  - Options (null = valeur par défaut déjà appliquée) :"
        printf '%s ' "${optional[@]}" | fold -s -w 90 | sed 's/^/      /'
        echo
    fi
    if (( ANSWERS_CUSTOM_COUNT > 0 )); then
        echo "  - ${ANSWERS_CUSTOM_COUNT} variable(s) inconnue(s) du modèle rangée(s) dans le groupe \"personnalise\"."
    fi
    return "$rc"
}

# Lancement normal sans fichier de réponses, en terminal : propose de créer le modèle et de s'arrêter
# pour le compléter tranquillement (sinon : questions interactives, fichier généré ensuite).
answers_offer_template() {

    [[ "$ANSWERS_FILE_LOADED" != "true" && ! -e "$ANSWERS_FILE" && -t 0 ]] || return 0

    local choice
    echo
    echo "Aucun fichier de réponses (${ANSWERS_FILE})."
    echo "  1) Créer le fichier modèle (JSON) et m'arrêter : je le complète puis je relance ./install.sh (recommandé)"
    echo "  2) Continuer avec les questions interactives (le fichier sera généré avec mes réponses)"
    read -r -p "Choix [1/2] : " choice || choice=2

    if [[ "$choice" == "1" ]]; then
        answers_update_file "$ANSWERS_FILE" force || true
        exit 0
    fi
    return 0
}

# Lancement normal : met à jour ; s'arrête seulement si des variables REQUISES sont nouvelles.
answers_check_new_vars() {

    [[ "${ANSWERS_CHECK:-true}" == "true" ]] || return 0
    [[ -f "$ANSWERS_FILE" ]] || return 0

    local rc=0
    answers_update_file "$ANSWERS_FILE" || rc=$?

    if (( rc == 10 )); then
        echo
        echo "ARRÊT : de nouvelles variables à renseigner sont disponibles. Complète-les, puis relance ./install.sh"
        echo "(ignorer : ./install.sh --skip-answers-check)"
        exit 0
    fi
    (( rc == 0 )) || exit 1
    return 0
}


usage_text() {
    cat <<'USAGE_EOF'
PROXMOX HOMELAB INSTALLER — options du script

USAGE
  ./install.sh [fichier-réponses.json]          Installation (fichier par défaut : ./proxmox-homelab-answers.json).
                                                Sans fichier : questions interactives, puis le fichier est GÉNÉRÉ
                                                avec tes réponses (mots de passe compris, droits 600).
  ./install.sh --init-answers [fichier]         CRÉE le fichier de réponses (JSON groupé par section) et la documentation
                                                proxmox-homelab-variables.md, et S'ARRÊTE : complète-le, puis relance ./install.sh.
                                                Si le fichier existe déjà, il est mis à jour.
  ./install.sh --update-answers [fichier]       Met à jour un fichier existant : tes valeurs sont conservées, les variables
                                                apparues depuis sont ajoutées (null = défaut, listées dans « _nouveau ») ; ancien en .bak.
  ./install.sh --describe [VARIABLE]            Décrit une variable (ou toutes celles dont le nom commence ainsi) ; sans argument : la liste.
  ./install.sh --skip-answers-check [fichier]   Installe sans s'arrêter pour les variables nouvelles.
  ./install.sh --run <fonction> [arguments]     Exécute UNE fonction (réparations, gestion, tests) : voir la liste ci-dessous.
  ./install.sh --ssh_key_sync [--replace] | --ssh_external_on [jours] | --ssh_external_expand <jours> | --ssh_external_off | --ssh_external_status | --ssh_external_diag
                                                Images stockées        images_status  images_purge  (image cloud des VM, template des CT, pilote NVIDIA : gardés sur le disque de l'OS)
  SSH depuis l'extérieur, temporaire (raccourcis de --run ; voir SSH_EXTERNAL).
  ./install.sh --sites-status                   Plusieurs domaines : état des sites (section "sites" du fichier de réponses) et de leurs dossiers.
  ./install.sh --site-add domaine.tld [svc1,svc2] [/racine]   Déclare un site dans le fichier de réponses et crée ses dossiers.
  ./install.sh --list-commands                  Affiche les fonctions utilisables avec --run.
  ./install.sh --help | -h                      Cette aide.        ./install.sh --version   Version.

VARIABLES D'ENVIRONNEMENT
  ANSWERS_CHECK=false     Ne pas s'arrêter pour les variables nouvelles (équivaut à --skip-answers-check).
  ANSWERS_SAVE=false      Ne pas générer le fichier de réponses après une installation interactive.

FICHIER DE RÉPONSES
  Fichier JSON groupé par section ; null (ou absent) = valeur par défaut du script ; variables décrites dans
  proxmox-homelab-variables.md et par --describe. Sans fichier, les questions ne portent que sur l'essentiel (domaine, e-mail,
  mots de passe, disque, services existants).
USAGE_EOF
}

commands_text() {
    cat <<'CMD_EOF'
FONCTIONS UTILISABLES AVEC  ./install.sh --run <fonction>
  Sites (domaines)       sites_status  site_add <domaine> [svc1,svc2] [/racine]  (aussi --sites-status / --site-add)
  Réseau / certificats   check_letsencrypt  verify_swag_certificate  swag_backup_certs  swag_restore_certs  swag_regenerate_certs
                         repair_swag_subdomains (applique les sous-domaines choisis)  repair_swag_add_media|photo_alias|office|node|monitor|mail
  Portail (accueil)      portal_apply (régénère la page d'accueil des services après ajout/retrait d'un service)
  SSH depuis l'extérieur ssh_external_on [jours]  ssh_key_sync [--replace]  ssh_external_expand <jours>  ssh_external_off  ssh_external_status  ssh_external_diag  (temporaire, clé SSH seulement ; aussi en option : ./install.sh --ssh_external_expand 7)
  IA locale              ai_gpu_attach (après redémarrage de l'hôte)  ai_pull_models  ai_sync_now  ai_prepare_docs_dir  ai_status  ai_budget
  DNS                    dns_zone_generate (fichier de zone à publier)  dns_configure  dns_update  dns_check  dns_stats  dns_logs
  VPN WireGuard / Tor    wg_add_peer <nom> <lan|backup|internet|tor>  wg_show_peer <nom>  wg_remove_peer  wg_list_peers  wg_status
                         wg_add_exit  wg_test_exits  wg_tor_setup  wg_test_tor  wg_update_cli  deploy_wireguard
  Sauvegardes            backup_status  backup_source_export  backup_offsite_run  configure_backup_pull_access  configure_usb_export
                         usb_export_now  usb_marker_generate  db_dump_now  db_dump_status  db_restore_help  restore_test_now  restore_test_status
  Notifications          configure_notify  notify_test  health_check  telegram_chat_id  telegram_test  telegram_totp_show  telegram_totp_reset
  VM Docker (disque)     docker_disk_grow <ex. 32G>  docker_prune  docker_log_rotation_apply  guests_move_storage [apply] [storage]
  Nextcloud / PHP        nextcloud_optimize  nextcloud_stack_apply  php_cve_check  php_cve_hunt  php_cve_fix  docker_vm_cpu_apply [reboot]
                         nextcloud_photos_setup  nextcloud_photos_scan  nextcloud_photos_classify start|stop|status  nextcloud_photos_status
  Applications           repair_nextcloud_proxy  repair_nextcloud_data_mount  configure_nextcloud_office  repair_syncin_stack  syncin_editors_apply
                          docker_update_check  docker_update_apply  deploy_arr_stack  arr_status  arr_logs  arr_vpn_check
  Autres services        node_restart  node_logs  node_backup_mongo  node_fix_mongo_kernel  mail_add_account  mail_dkim  mail_check  mail_logs
                         crowdsec_status  crowdsec_ban|unban  monitor_list  monitor_logs  repair_webmin  diagnose_webmin
CMD_EOF
}

case "${1:-}" in
    --help | -h)        usage_text; echo; commands_text; exit 0 ;;
    --list-commands)    commands_text; exit 0 ;;
    --version)          echo "proxmox-homelab-install ${SCRIPT_VERSION}"; exit 0 ;;
    --init-answers)
        # Crée le modèle et s'arrête (ou met à jour un fichier existant) : à compléter avant de relancer
        answers_update_file "${2:-./proxmox-homelab-answers.json}" force || { _rc=$?; [[ "$_rc" == "10" ]] || exit "$_rc"; }
        exit 0 ;;
    --describe)
        answers_describe "${2:-}" || exit 1
        exit 0 ;;
esac

if [[ "${1:-}" == "--update-answers" ]]; then
    answers_update_file "${2:-./proxmox-homelab-answers.json}" force || { _rc=$?; [[ "$_rc" == "10" ]] || exit "$_rc"; }
    exit 0
fi

if [[ "${1:-}" == "--skip-answers-check" ]]; then
    ANSWERS_CHECK=false
    shift
    ANSWERS_FILE="${1:-./proxmox-homelab-answers.json}"     # 00-config l'avait calculé avant le décalage
fi
