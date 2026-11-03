#!/bin/bash
#
# Configurações iniciais para uma VM recém-instalada com Ubuntu Server.
#
# Por padrão, libera o uso de sudo sem senha para o usuário que executou o
# script. As demais configurações são opcionais e ativadas por parâmetro
# (veja --help).

# Interrompe o script no primeiro erro (-e), ao usar variável não definida (-u)
# ou quando qualquer comando de um pipe falhar (pipefail).
set -euo pipefail


#################################################################
# Configurações
#################################################################

readonly SUDOERS_FILE="/etc/sudoers.d/90-init-users"
readonly GRUB_FILE="/etc/default/grub"
readonly TIMESYNCD_FILE="/etc/systemd/timesyncd.conf"

readonly TIMEZONE="America/Fortaleza"
readonly NTP_SERVER="pool.ntp.br"
# Usado só se não for possível ler o FallbackNTP do próprio timesyncd.conf.
readonly NTP_FALLBACK_DEFAULT="ntp.ubuntu.com"

# Usuário que chamou o sudo (ou o usuário atual, se o script rodar direto como root).
readonly TARGET_USER="${SUDO_USER:-$(id -un)}"

# Preenchidas por parse_args.
DO_DISABLE_IPV6=false
DO_NTP_BR=false


#################################################################
# Funções auxiliares
#################################################################

function print_help {
    cat <<EOF
Configurações iniciais para Ubuntu Server.

Por padrão, adiciona o usuário que executou o script ao sudoers, sem exigir
senha. Se o usuário for root, esta etapa é ignorada.

Uso:
    sudo ./initial-config.sh [OPÇÕES]

Opções:

  --disable-ipv6    Desabilita o IPv6 adicionando um parâmetro na
                    configuração do GRUB.
  --ntp-br          Define o fuso horário como ${TIMEZONE} e usa
                    ${NTP_SERVER} como servidor NTP.
  --help            Exibe esta mensagem e sai.

EOF
}


function log {
    echo "==> $*"
}


function die {
    echo "Erro: $*" >&2
    exit 1
}


function backup_file {
    # Guarda uma cópia do arquivo original antes de alterá-lo. Se o backup já
    # existir, não sobrescreve: assim o .bak sempre guarda a versão original,
    # mesmo que o script seja executado várias vezes.

    local file="$1"
    if [[ ! -e "${file}.bak" ]]
    then
        cp -a "${file}" "${file}.bak"
        log "Backup criado: ${file}.bak"
    fi
}


#################################################################
# Tarefas
#################################################################

function configure_passwordless_sudo {
    local user="$1"
    log "Liberando sudo sem senha para '${user}'"

    # Um arquivo inválido em /etc/sudoers.d quebra o sudo por completo.
    # Por isso o arquivo é gerado em um local temporário, validado com o
    # visudo e só então instalado, com a permissão que o sudo exige (0440).
    local tmp_file
    tmp_file="$(mktemp)"
    cat > "${tmp_file}" <<EOF
# Regras para o usuário ${user}
${user} ALL=(ALL) NOPASSWD:ALL
EOF

    if ! visudo -cqf "${tmp_file}"
    then
        rm -f "${tmp_file}"
        die "o arquivo de sudoers gerado é inválido; nada foi alterado."
    fi

    install -m 0440 -o root -g root "${tmp_file}" "${SUDOERS_FILE}"
    rm -f "${tmp_file}"

    usermod -aG sudo "${user}"
}


function disable_ipv6 {
    log "Desabilitando IPv6 no GRUB"
    backup_file "${GRUB_FILE}"

    # O parâmetro é adicionado nas duas variáveis do GRUB: na prática, só
    # funcionou como esperado assim.
    local changed=false
    local var
    for var in GRUB_CMDLINE_LINUX_DEFAULT GRUB_CMDLINE_LINUX
    do
        # Não adiciona de novo se o parâmetro já estiver lá.
        if grep -qE "^${var}=\".*ipv6\.disable=1" "${GRUB_FILE}"
        then
            log "${var} já contém ipv6.disable=1"
            continue
        fi

        # Acrescenta ' ipv6.disable=1' no fim do valor entre aspas.
        #   Antes:  GRUB_CMDLINE_LINUX="quiet splash"
        #   Depois: GRUB_CMDLINE_LINUX="quiet splash ipv6.disable=1"
        # O grupo ([^"]*) captura tudo o que está entre as aspas e o \1 o
        # reaproveita na substituição.
        sed -i -E "s/^${var}=\"([^\"]*)\"/${var}=\"\1 ipv6.disable=1\"/" "${GRUB_FILE}"
        changed=true
    done

    if [[ "${changed}" == true ]]
    then
        update-grub
        log "IPv6 será desabilitado após reiniciar a máquina"
    fi
}


function read_current_ntp_fallback {
    # Imprime o valor de FallbackNTP do timesyncd.conf, esteja a linha
    # comentada ou não. Exemplo: "#FallbackNTP=ntp.ubuntu.com" -> "ntp.ubuntu.com".
    # Não imprime nada se a linha não existir ou estiver vazia.

    local line
    # -m 1: para na primeira linha encontrada. O "|| true" evita que o
    # script seja interrompido (set -e) quando o grep não encontra nada.
    line="$(grep -m 1 -E '^#?FallbackNTP=' "${TIMESYNCD_FILE}" || true)"

    # Remove tudo até o primeiro "=", inclusive, ficando só com o valor.
    local value="${line#*=}"

    # O "read" remove os espaços do início e do fim do valor.
    read -r value <<< "${value}"
    echo "${value}"
}


function configure_ntp_br {
    log "Configurando fuso horário (${TIMEZONE}) e NTP (${NTP_SERVER})"

    local ntp_fallback
    ntp_fallback="$(read_current_ntp_fallback)"
    if [[ -z "${ntp_fallback}" ]]
    then
        ntp_fallback="${NTP_FALLBACK_DEFAULT}"
    fi

    timedatectl set-timezone "${TIMEZONE}"

    backup_file "${TIMESYNCD_FILE}"

    # Substitui as linhas NTP= e FallbackNTP=, removendo o "#" se a linha
    # estiver comentada. O "|" é usado como separador do sed no lugar de "/"
    # para não conflitar com algum caractere dos valores.
    sed -i -E \
        -e "s|^#?NTP=.*$|NTP=${NTP_SERVER}|" \
        -e "s|^#?FallbackNTP=.*$|FallbackNTP=${ntp_fallback}|" \
        "${TIMESYNCD_FILE}"

    timedatectl set-ntp true
    systemctl restart systemd-timesyncd.service
}


#################################################################
# Execução
#################################################################

function parse_args {
    # Apenas registra o que foi pedido. A execução das tarefas fica no main.

    local arg
    for arg in "$@"
    do
        case "${arg}" in
            --disable-ipv6)
                DO_DISABLE_IPV6=true
                ;;
            --ntp-br)
                DO_NTP_BR=true
                ;;
            --help)
                print_help
                exit 0
                ;;
            *)
                echo "Opção desconhecida: ${arg}" >&2
                echo >&2
                print_help >&2
                exit 1
                ;;
        esac
    done
}


function main {
    parse_args "$@"

    if [[ "$(id -ru)" != "0" ]]
    then
        die "execute este script com privilégios de root (sudo)."
    fi

    # Sempre executado.
    if [[ "${TARGET_USER}" != "root" ]]
    then
        configure_passwordless_sudo "${TARGET_USER}"
    fi

    if [[ "${DO_DISABLE_IPV6}" == true ]]
    then
        disable_ipv6
    fi

    if [[ "${DO_NTP_BR}" == true ]]
    then
        configure_ntp_br
    fi

    log "Concluído"
}


main "$@"
