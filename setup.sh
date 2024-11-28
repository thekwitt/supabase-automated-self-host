#!/bin/bash

# https://stackoverflow.com/a/18216122/18954618
if [ "$EUID" -ne 0 ]; then
    echo "Please run this script as root user"
    exit 1
fi

# UPGRADE PACKAGES
apt update && apt upgrade -y && apt install -y apache2-utils jq openssl

# SET UP FIREWALL
# echo "Setting up ufw"
# ufw --force enable
# ports=("ssh" "http" "https")
# for port in "${ports[@]}"; do ufw allow "$port"; done

echo "Setting up Docker"

# https://stackoverflow.com/a/677212
if ! command -v /usr/bin/docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | sh >/dev/null

    # https://stackoverflow.com/a/36131231
    if [ -z "$(getent group docker)" ]; then
        groupadd docker
    fi

    usermod -aG docker "$USER"
else
    echo "docker already installed. skipping installation"
fi

git clone https://github.com/singh-inder/supabase-self-host

if ! cd supabase/docker; then
    echo "Unable to access supabase/docker directory"
    exit 1
fi

if [[ ! -f ".env.example" ]]; then
    echo ".env.example file not found. Exiting!"
    exit 1
fi

read -rp "Enter your domain: " domain

# https://www.baeldung.com/linux/bcrypt-hash#using-htpasswd
# -b option is for running htpasswd in batch mode, that is, it gets the password from the command line. If we don’t use the -b option, htpasswd prompts us to enter the password, and the typed password isn’t visible on the command line.
# -B option specifies that bcrypt should be used for hashing passwords. There are also other options for hashing. For example, the -m option uses MD5, while the -s option uses SHA
# -n option shows the hashed password on the standard output.
# -C option can be used together with the -B option. It sets the bcrypt “cost”, or the time used by the bcrypt algorithm to compute the hash. htpasswd accepts values within 4 and 17 inclusively and the default value is 5
read -rp "Enter supabase dashboard username: " dashboardUsername
read -rp "Enter supabase dashboard password: " dashboardPassword

dashboardPassword=$(htpasswd -bnBC 12 "" "$dashboardPassword" | cut -d : -f 2)

# https://www.willhaley.com/blog/generate-jwt-with-bash/

jwt_secret=$(openssl rand -hex 40)

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
iat=$(date +%s)
exp=$(("$iat" + 4 * 3600 * 24 * 365)) # 4 years expiry

gen_token() {
    # local payload=$(
    #     # 4 years expiry
    #     echo "$1" | jq --arg time_str "$(date +%s)" \
    #         '
    # ($time_str | tonumber) as $time_num
    # | .iat=$time_num
    # | .exp=($time_num + ((4*3600*24*365)))
    # '
    # )

    # use the same iat and exp for anon_token and service_role_token
    local payload=$(
        echo "$1" | jq --arg jq_iat "$iat" --arg jq_exp "$exp" '.iat=($jq_iat | tonumber) | .exp=($jq_exp | tonumber)'
    )

    local payload_base64=$(echo "${payload}" | json | base64_encode)

    local header_payload="${header_base64}.${payload_base64}"

    local signature=$(echo "${header_payload}" | hmacsha256_sign | base64_encode)

    echo "${header_payload}.${signature}"
}

anon_token=$(gen_token '{"role": "anon", "iss": "supabase"}')
service_role_token=$(gen_token '{"role": "service_role", "iss": "supabase"}')

sed -e "s|POSTGRES_PASSWORD.*|POSTGRES_PASSWORD=$(openssl rand -hex 16)|" \
    -e "s|JWT_SECRET.*|JWT_SECRET=$jwt_secret|" \
    -e "s|ANON_KEY.*|ANON_KEY=$anon_token|" \
    -e "s|SERVICE_ROLE_KEY.*|SERVICE_ROLE_KEY=$service_role_token|" \
    -e "s|API_EXTERNAL_URL.*|API_EXTERNAL_URL=$domain/api|" \
    -e "s|SUPABASE_PUBLIC_URL.*|SUPABASE_PUBLIC_URL=$domain|" ".env.example" >.env

echo -e "\nDOMAIN=$domain" >>.env

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
