#!/bin/bash

set -euo pipefail

: "${CI:=false}"
: "${WITH_REDIS:=false}"

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

detect_arch() {
    case $(uname -m) in
    x86_64) echo "amd64" ;;
    aarch64) echo "arm64" ;;
    armv7l) echo "arm" ;;
    i686 | i386) echo "386" ;;
    *) echo "err" ;;
    esac
}

#https://stackoverflow.com/a/18434831/18954618
detect_os() {
    case $(uname | tr '[:upper:]' '[:lower:]') in
    linux*) echo "linux" ;;
    darwin*) echo "darwin" ;;
    *) echo "err" ;;
    esac
}

os="$(detect_os)"
arch="$(detect_arch)"

if [[ "$os" == "err" ]]; then
    error_log "This script only supports linux and macos"
    exit 1
fi

if [[ "$arch" == "err" ]]; then
    error_log "Unsupported cpu architecture"
    exit 1
fi

with_authelia=false
if [[ "$#" -gt 0 && "$1" == "--with-authelia" ]]; then with_authelia=true; fi

packages=(curl apache2-utils jq openssl git)

# set -e doesn't work if any command is part of an if statement. package installation errors have to be checked https://stackoverflow.com/a/821419/18954618
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
    error_log "Failed to install packages: Package manager not found. You must manually install: ${packages[*]}"
    exit 1
fi

if [ $? -ne 0 ]; then
    error_log "Failed to install packages. You must manually install: ${packages[*]}"
    exit 1
fi

# https://stackoverflow.com/a/677212
if ! command -v /usr/bin/docker >/dev/null; then
    info_log "Setting up docker"

    if ! curl -fsSL https://get.docker.com | sh; then
        error_log "Docker installation failed. Exiting!"
        exit 1
    fi
else
    info_log "docker already installed. skipping installation"
fi

githubAc="https://github.com/singh-inder"
repoUrl="$githubAc/supabase-automated-self-host"
directory="$(basename "$repoUrl")"

if [ -d "$directory" ]; then
    info_log "$directory directory present, skipping git clone"
else
    git clone "$repoUrl" "$directory"
fi

if ! cd "$directory"/docker; then
    error_log "Unable to access $directory/docker directory"
    exit 1
fi

if [ ! -f ".env.example" ]; then
    error_log ".env.example file not found. Exiting!"
    exit 1
fi

downloadLocation="/usr/local/bin"

if [ ! -x "$downloadLocation"/url-parser ]; then
    info_log "Downloading url-parser from $githubAc/url-parser and saving in $downloadLocation"
    wget "$githubAc"/url-parser/releases/download/v1.1.0/url-parser-"$os"-"$arch" -O "$downloadLocation"/url-parser &>/dev/null &&
        chmod +x "$downloadLocation"/url-parser &>/dev/null
fi

if [ ! -x "$downloadLocation"/yq ]; then
    info_log "Downloading yq from https://github.com/mikefarah/yq and saving in $downloadLocation"
    wget https://github.com/mikefarah/yq/releases/download/v4.44.6/yq_"$os"_"$arch" -O "$downloadLocation"/yq &>/dev/null &&
        chmod +x "$downloadLocation"/yq &>/dev/null
fi

echo -e "---------------------------------------------------------------------------\n"

format_prompt() {
    echo -e "${CYAN}$1${NO_COLOR}"
}
confirmation_prompt() {
    # bash variable are passed by value.
    local variable_to_update_name="$1"
    local answer=""
    read -rp "$(format_prompt "$2")" answer

    # converts input to lowercase
    case "${answer,,}" in
    y | yes)
        answer=true
        ;;
    n | no)
        answer=false
        ;;
    *)
        error_log "Please answer yes or no\n"
        answer=""
        ;;
    esac

    # Use eval to dynamically assign the new value to the variable passed by name. This indirectly updates the variable in the caller's scope.
    if [ -n "$answer" ]; then eval "$variable_to_update_name=$answer"; fi
}

domain=""
while [ -z "$domain" ]; do
    if [ "$CI" == true ]; then
        domain="https://supabase.example.com"
    else
        read -rp "$(format_prompt "Enter your domain:") " domain
    fi

    protocol="$(url-parser --url "$domain" --get scheme)"

    if [[ "$with_authelia" == true ]]; then
        # cookies.authelia_url needs to be https https://www.authelia.com/configuration/session/introduction/#authelia_url
        if [[ "$protocol" != "https" ]]; then
            error_log "As you've enabled --with-authelia flag, url protocol needs to https"
            domain=""
        else
            registered_domain="$(url-parser --url "$domain" --get registeredDomain)"

            if [ -z "$registered_domain" ]; then
                error_log "Error extracting root domain\n"
                domain=""
            fi
        fi

    elif [[ "$protocol" != "http" && "$protocol" != "https" ]]; then
        error_log "Url protocol must be http or https\n"
        domain=""
    fi
done

username=""
if [[ "$CI" == true ]]; then username="inder"; fi

while [ -z "$username" ]; do
    read -rp "$(format_prompt "Enter username:") " username

    # https://stackoverflow.com/questions/18041761/bash-need-to-test-for-alphanumeric-string
    if [[ ! "$username" =~ ^[a-zA-Z0-9]+$ ]]; then
        error_log "Only alphabets and numbers are allowed"
        username=""
    fi
    # read command automatically trims leading & trailing whitespace. No need to handle it separately
done

password=""
confirmPassword=""

if [[ "$CI" == true ]]; then
    password="password"
    confirmPassword="password"
fi

while [[ -z "$password" || "$password" != "$confirmPassword" ]]; do
    read -s -rp "$(format_prompt "Enter password(password is hidden):") " password
    echo
    read -s -rp "$(format_prompt "Confirm password:") " confirmPassword
    echo

    if [[ "$password" != "$confirmPassword" ]]; then
        error_log "Password mismatch. Please try again!\n"
    fi
done

autoConfirm=""
if [[ "$CI" == true ]]; then autoConfirm="false"; fi

while [ -z "$autoConfirm" ]; do
    confirmation_prompt autoConfirm "Do you want to send confirmation emails to register users? If yes, you'll have to setup your own SMTP server [y/n]: "
    if [[ "$autoConfirm" == true ]]; then
        autoConfirm="false"
    elif [[ "$autoConfirm" == false ]]; then
        autoConfirm="true"
    fi

done

# If with_authelia, then additionally ask for email and display name
if [[ "$with_authelia" == true ]]; then
    email=""
    display_name=""
    setup_redis=""

    if [[ "$CI" == true ]]; then
        email="johndoe@gmail.com"
        display_name="Inder Singh"
        if [[ "$WITH_REDIS" == true ]]; then setup_redis=true; fi
    fi

    while [ -z "$email" ]; do
        read -rp "$(format_prompt "Enter your email:") " email

        # split email string on @ symbol
        IFS="@" read -r before_at after_at <<<"$email"

        if [[ -z "$before_at" || -z "$after_at" ]]; then
            error_log "Invalid email"
            email=""
        fi
    done

    while [ -z "$display_name" ]; do
        read -rp "$(format_prompt "Enter Display Name:") " display_name

        if [[ ! "$display_name" =~ ^[a-zA-Z0-9[:space:]]+$ ]]; then
            error_log "Only alphabets, numbers and spaces are allowed"
            display_name=""
        fi
    done

    while [[ "$CI" == false && -z "$setup_redis" ]]; do
        confirmation_prompt setup_redis "Do you want to setup redis with authelia? [y/n]: "
    done
fi

info_log "Finishing..."

# https://www.baeldung.com/linux/bcrypt-hash#using-htpasswd
# -b option is for running htpasswd in batch mode, that is, it gets the password from the command line. If we don’t use the -b option, htpasswd prompts us to enter the password, and the typed password isn’t visible on the command line.
# -B option specifies that bcrypt should be used for hashing passwords. There are also other options for hashing. For example, the -m option uses MD5, while the -s option uses SHA
# -n option shows the hashed password on the standard output.
# -C option can be used together with the -B option. It sets the bcrypt “cost”, or the time used by the bcrypt algorithm to compute the hash. htpasswd accepts values within 4 and 17 inclusively and the default value is 5
password=$(htpasswd -bnBC 12 "" "$password" | cut -d : -f 2)

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

gen_hex() {
    openssl rand -hex "$1"
}

sed -e "s|POSTGRES_PASSWORD.*|POSTGRES_PASSWORD=$(gen_hex 16)|" \
    -e "s|JWT_SECRET.*|JWT_SECRET=$jwt_secret|" \
    -e "s|ANON_KEY.*|ANON_KEY=$anon_token|" \
    -e "s|SERVICE_ROLE_KEY.*|SERVICE_ROLE_KEY=$service_role_token|" \
    -e "s|API_EXTERNAL_URL.*|API_EXTERNAL_URL=$domain/api|" \
    -e "s|SUPABASE_PUBLIC_URL.*|SUPABASE_PUBLIC_URL=$domain|" \
    -e "s|ENABLE_EMAIL_AUTOCONFIRM.*|ENABLE_EMAIL_AUTOCONFIRM=$autoConfirm|" .env.example >.env

format_yaml() {
    local filepath="$1"
    local yq_command="$2"

    # https://github.com/mikefarah/yq/issues/465#issuecomment-2265381565
    sed -i '/^\r\{0,1\}$/s// #BLANK_LINE/' "$filepath"

    eval "$yq_command \"$filepath\""

    sed -i "s/ *#BLANK_LINE//g" "$1"
}

compose_file="docker-compose.yml"

if [[ "$with_authelia" == false ]]; then
    echo -e "\nCADDY_AUTH_USERNAME=$username\nCADDY_AUTH_PASSWORD='$password'" >>.env

    format_yaml "$compose_file" "yq -i '.services.caddy.environment.CADDY_AUTH_USERNAME = \"\${CADDY_AUTH_USERNAME?:error}\" |
           .services.caddy.environment.CADDY_AUTH_PASSWORD = \"\${CADDY_AUTH_PASSWORD?:error}\"
           '"
else
    authelia_config_file="./volumes/authelia/configuration.yml"
    # Dynamically update yaml path from env https://github.com/mikefarah/yq/discussions/1253
    # https://mikefarah.gitbook.io/yq/operators/style

    # WRITE AUTHELIA users_database.yml file
    # adding disabled=false after updating style to double so that every value except disabled is double quoted
    yaml_path=".users.$username" displayName="$display_name" password="$password" email="$email" \
        yq -n 'eval(strenv(yaml_path)).displayname = strenv(displayName) |
               eval(strenv(yaml_path)).password = strenv(password) | 
               eval(strenv(yaml_path)).email = strenv(email) | 
               eval(strenv(yaml_path)).groups = ["admins","dev"] | 
               .. style="double" | 
               eval(strenv(yaml_path)).disabled = false' >./volumes/authelia/users_database.yml

    host="$(url-parser --url "$domain" --get host)"
    registered_domain="$(url-parser --url "$domain" --get registeredDomain)"

    # UPDATE AUTHELIA CONFIGURATION FILE
    host="$host" registered_domain="$registered_domain" authelia_url="$domain"/authenticate redirect_url="$domain" \
        format_yaml "$authelia_config_file" \
        "yq -i '.access_control.rules[0].domain=strenv(host) | 
            .session.cookies[0].domain=strenv(registered_domain) | 
            .session.cookies[0].authelia_url=strenv(authelia_url) |
            .session.cookies[0].default_redirection_url=strenv(redirect_url)'"

    echo -e "\nAUTHELIA_SESSION_SECRET=$(gen_hex 32)\nAUTHELIA_STORAGE_ENCRYPTION_KEY=$(gen_hex 32)\nAUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET=$(gen_hex 32)" \
        >>.env

    # Update docker-compose.yml file
    authelia_schema="authelia" format_yaml "$compose_file" "yq -i '.services.authelia.container_name = \"authelia\" |
       .services.authelia.image = \"authelia/authelia:4.38\" |
       .services.authelia.volumes = [\"./volumes/authelia:/config\"] |
       .services.authelia.depends_on.db.condition = \"service_healthy\" |
       .services.authelia.expose = [9091] |    
       .services.authelia.restart = \"unless-stopped\" |    
       .services.authelia.healthcheck.disable = false |
       .services.authelia.environment = {
         \"AUTHELIA_STORAGE_POSTGRES_ADDRESS\": \"tcp://db:5432\",
         \"AUTHELIA_STORAGE_POSTGRES_USERNAME\": \"postgres\",
         \"AUTHELIA_STORAGE_POSTGRES_PASSWORD\" : \"\${POSTGRES_PASSWORD}\",
         \"AUTHELIA_STORAGE_POSTGRES_DATABASE\" : \"\${POSTGRES_DB}\",
         \"AUTHELIA_STORAGE_POSTGRES_SCHEMA\" : strenv(authelia_schema),
         \"AUTHELIA_SESSION_SECRET\": \"\${AUTHELIA_SESSION_SECRET:?error}\",
         \"AUTHELIA_STORAGE_ENCRYPTION_KEY\": \"\${AUTHELIA_STORAGE_ENCRYPTION_KEY:?error}\",
         \"AUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET\": \"\${AUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET:?error}\"
       } |
       
       .services.db.environment.AUTHELIA_SCHEMA = strenv(authelia_schema) |
       .services.db.volumes += \"./volumes/db/schema-authelia.sh:/docker-entrypoint-initdb.d/schema-authelia.sh\"
       '"

    if [[ "$setup_redis" == true ]]; then
        format_yaml "$authelia_config_file" "yq -i '.session.redis.host=\"redis\" | .session.redis.port=6379'"

        format_yaml "$compose_file" \
            "yq -i '.services.redis.container_name=\"redis\" |
                    .services.redis.image=\"redis:7.4\" |
                    .services.redis.expose=[6379] |
                    .services.redis.healthcheck={
                    \"test\" : [\"CMD-SHELL\",\"redis-cli ping | grep PONG\"],
                    \"timeout\" : \"5s\",
                    \"interval\" : \"1s\",
                    \"retries\" : 5
                    } |
                    .services.authelia.depends_on.redis.condition=\"service_healthy\"'"
    fi
fi

# https://stackoverflow.com/a/3953712/18954618
echo -e "{\$DOMAIN} {
        $([[ "$CI" == true ]] && echo "tls internal")
        @api path /rest/v1/* /auth/v1/* /realtime/v1/* /storage/v1/* /api*

        $([[ "$with_authelia" == true ]] && echo "@authelia path /authenticate /authenticate/*
        handle @authelia {
                reverse_proxy authelia:9091
        }
        ")

        handle @api {
		    reverse_proxy @api kong:8000
	    }   

       	handle {
            $([[ "$with_authelia" == false ]] && echo "basic_auth {
			    {\$CADDY_AUTH_USERNAME} {\$CADDY_AUTH_PASSWORD}
		    }" || echo "forward_auth authelia:9091 {
                        uri /api/authz/forward-auth

                        copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
                }")	    	

		    reverse_proxy studio:3000
	    }
}" >Caddyfile

unset password confirmPassword

echo -e "\n🎉 Success! The script completed successfully."
echo "👉 Next steps:"
echo "1. Change into the Supabase Docker directory:"
echo "   cd supabase/docker"
echo "2. Start the services with Docker Compose:"
echo "   docker compose up -d"
echo "🚀 Your Supabase services should now be running!"

echo -e "\n🌐 To access the dashboard over the internet, ensure your firewall allows traffic on ports 80 and 443\n"
