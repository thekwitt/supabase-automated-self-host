#!/bin/bash

NO_COLOR=''
RED=''
CYAN=''

# Check if terminal supports colors https://unix.stackexchange.com/a/10065/642181
if [ -t 1 ]; then
    total_colors=$(tput colors)
    if [[ -n "$total_colors" && $total_colors -ge 8 ]]; then
        # https://stackoverflow.com/a/28938235/18954618
        NO_COLOR='\033[0m'
        RED='\033[0;31m'
        CYAN='\033[0;36m'
    fi
fi

error_log() {
    echo -e "${RED}ERROR: $1${NO_COLOR}"
}
info_log() {
    echo -e "${CYAN}INFO: $1${NO_COLOR}"
}

# https://stackoverflow.com/a/18216122/18954618
if [ "$EUID" -ne 0 ]; then
    error_log "Please run this script as root user"
    exit 1
fi

packages=(curl apache2-utils jq openssl git)

# https://unix.stackexchange.com/a/571192/642181
if [ -x "$(command -v apt-get)" ]; then
    apt-get update && apt-get install -y "${packages[@]}"

elif [ -x "$(command -v apk)" ]; then
    apk update && apk add --no-cache "${packages[@]}"

elif [ -x "$(command -v dnf)" ]; then
    dnf makecache && dnf install -y "${packages[@]}"

elif [ -x "$(command -v zypper)" ]; then
    zypper refresh && zypper install "${packages[@]}"

elif [ -x "$(command -v pacman)" ]; then
    pacman -Syu --noconfirm "${packages[@]}"

elif [ -x "$(command -v pkg)" ]; then
    pkg update && pkg install -y "${packages[@]}"

else
    # diff between array expansion with "@" and "*" https://linuxsimply.com/bash-scripting-tutorial/expansion/array-expansion/
    error_log "Failed to install packages: Package manager not found. You must manually install: ${packages[*]}" >&2
    exit 1
fi

if [ $? -ne 0 ]; then
    error_log "Failed to install packages. You must manually install: ${packages[*]}" >&2
    exit 1
fi

info_log "Setting up docker"

# https://stackoverflow.com/a/677212
if ! command -v /usr/bin/docker >/dev/null; then
    if ! curl -fsSL https://get.docker.com | sh; then
        error_log "Docker installation failed. Exiting!" >&2
        exit 1
    fi
else
    info_log "docker already installed. skipping installation"
fi

directory="supabase"

if [ -d "$directory" ]; then
    info_log "$directory directory present, skipping git clone"
else
    git clone https://github.com/singh-inder/supabase-automated-self-host "$directory"
fi

if ! cd "$directory"/docker; then
    error_log "Unable to access $directory/docker directory"
    exit 1
fi

if [ ! -f ".env.example" ]; then
    error_log ".env.example file not found. Exiting!"
    exit 1
fi

echo -e "---------------------------------------------------------------------------\n"

format_prompt() {
    echo -e "${CYAN}$1${NO_COLOR}"
}

domain=""
while [ -z "$domain" ]; do
    read -rp "$(format_prompt "Enter your domain:") " domain
done

dashboardUsername=""
while [ -z "$dashboardUsername" ]; do
    read -rp "$(format_prompt "Enter supabase dashboard username:") " dashboardUsername
done

dashboardPassword=""
dashboardConfirmPassword=""

while [[ -z "$dashboardPassword" || "$dashboardPassword" != "$dashboardConfirmPassword" ]]; do
    read -s -rp "$(format_prompt "Enter supabase dashboard password(password is hidden):") " dashboardPassword
    echo
    read -s -rp "$(format_prompt "Confirm password:") " dashboardConfirmPassword
    echo

    if [ "$dashboardPassword" != "$dashboardConfirmPassword" ]; then
        echo -e "Password mismatch. Please try again!\n"
    fi
done

autoConfirm=""

while true; do
    read -rp "$(format_prompt "Do you want to send confirmation emails to register users? If yes, you'll have to setup your own SMTP server [y/n]:") " autoConfirm
    case $autoConfirm in
    [yY] | [yY][eE][sS])
        autoConfirm="false"
        echo
        break
        ;;
    [nN] | [nN][oO])
        autoConfirm="true"
        echo
        break
        ;;
    *) echo -e "${RED}ERROR: Please answer yes or no${NO_COLOR}\n" ;;
    esac
done

info_log "Finishing..."

# https://www.baeldung.com/linux/bcrypt-hash#using-htpasswd
# -b option is for running htpasswd in batch mode, that is, it gets the password from the command line. If we don’t use the -b option, htpasswd prompts us to enter the password, and the typed password isn’t visible on the command line.
# -B option specifies that bcrypt should be used for hashing passwords. There are also other options for hashing. For example, the -m option uses MD5, while the -s option uses SHA
# -n option shows the hashed password on the standard output.
# -C option can be used together with the -B option. It sets the bcrypt “cost”, or the time used by the bcrypt algorithm to compute the hash. htpasswd accepts values within 4 and 17 inclusively and the default value is 5
dashboardPassword=$(htpasswd -bnBC 12 "" "$dashboardPassword" | cut -d : -f 2)

# https://www.willhaley.com/blog/generate-jwt-with-bash/

jwt_secret=$(openssl rand -hex 20)

base64_encode() {
    declare input=${1:-$(</dev/stdin)}
    # Use `tr` to URL encode the output from base64.
    printf '%s' "${input}" | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n'
}

json() {
    declare input=${1:-$(</dev/stdin)}
    printf '%s' "${input}" | jq -c .
}

hmacsha256_sign() {
    declare input=${1:-$(</dev/stdin)}
    printf '%s' "${input}" | openssl dgst -binary -sha256 -hmac "${jwt_secret}"
}

header='{"typ": "JWT","alg": "HS256"}'
header_base64=$(echo "${header}" | json | base64_encode)
# iat and exp for both tokens has to be same thats why initializing here
iat=$(date +%s)
exp=$(("$iat" + 5 * 3600 * 24 * 365)) # 5 years expiry

gen_token() {
    local payload=$(
        echo "$1" | jq --arg jq_iat "$iat" --arg jq_exp "$exp" '.iat=($jq_iat | tonumber) | .exp=($jq_exp | tonumber)'
    )

    local payload_base64=$(echo "${payload}" | json | base64_encode)

    local header_payload="${header_base64}.${payload_base64}"

    local signature=$(echo "${header_payload}" | hmacsha256_sign | base64_encode)

    echo "${header_payload}.${signature}"
}

anon_payload='{"role": "anon", "iss": "supabase"}'
anon_token=$(gen_token "$anon_payload")

service_role_payload='{"role": "service_role", "iss": "supabase"}'
service_role_token=$(gen_token "$service_role_payload")

# When double underscores ("__") are present in token, realtime analytics container remains unhealthy. Could be wrong about this behavior
# my guess it maybe something to do with how env's are passed by docker compose
# would say about 5/100 odds to have __ in token. for those 5 instances this loop:
while [[ "${anon_token}" == *"__"* || "${service_role_token}" == *"__"* ]]; do
    iat=$(date +%s)
    exp=$(("$iat" + 5 * 3600 * 24 * 365)) # 5 years expiry
    anon_token=$(gen_token "$anon_payload")
    service_role_token=$(gen_token "$service_role_payload")
done

sed -e "s|POSTGRES_PASSWORD.*|POSTGRES_PASSWORD=$(openssl rand -hex 16)|" \
    -e "s|JWT_SECRET.*|JWT_SECRET=$jwt_secret|" \
    -e "s|ANON_KEY.*|ANON_KEY=$anon_token|" \
    -e "s|SERVICE_ROLE_KEY.*|SERVICE_ROLE_KEY=$service_role_token|" \
    -e "s|API_EXTERNAL_URL.*|API_EXTERNAL_URL=$domain/api|" \
    -e "s|SUPABASE_PUBLIC_URL.*|SUPABASE_PUBLIC_URL=$domain|" \
    -e "s|ENABLE_EMAIL_AUTOCONFIRM.*|ENABLE_EMAIL_AUTOCONFIRM=$autoConfirm|" .env.example >.env

echo -e "{\$DOMAIN} {
        @api path /rest/v1/* /auth/v1/* /realtime/v1/* /storage/v1/* /api*

        handle @api {
		    reverse_proxy @api kong:8000
	    }   

       	handle {
	    	basic_auth {
			    $dashboardUsername $dashboardPassword
		    }

		    reverse_proxy studio:3000
	    }
}" >Caddyfile

unset dashboardPassword dashboardConfirmPassword

echo -e "\n🎉 Success! The script completed successfully."
echo "👉 Next steps:"
echo "1. Change into the Supabase Docker directory:"
echo "   cd supabase/docker"
echo "2. Start the services with Docker Compose:"
echo "   docker compose up -d"
echo "🚀 Your Supabase services should now be running!"

echo -e "\n🌐 To access the dashboard over the internet, ensure your firewall allows traffic on ports 80 and 443\n"
