# Supabase automated self host

Effortlessly deploy and manage your own self-hosted instance of Supabase with this fully automated setup script.

This project uses [Caddy](https://github.com/caddyserver/caddy) as reverse proxy with basic username & password authentication for supabase dashboard.
Dashboard password is hashed automatically. A random secure password is generated for the Postgres database. Random `jwt_secret`, `anon_key` & `service_role` keys are automatically generated

Note: This project is not officially supported by Supabase. For any information regarding Supabase itself you can refer to the [official documentation](https://supabase.com/docs). **The script has been tested only on Linux.**

## Prerequisites

- **A Linux Machine**: This can be a VPS or any personal computer running Linux with at least 1 GB RAM and 25 GB Disk space.

- **Domain Name**: A domain name is required **only if you want to access the dashboard over the internet**.

## Setup Instructions

1. Download `setup.sh` script

   ```bash
    curl -o setup.sh https://raw.githubusercontent.com/singh-inder/supabase-automated-self-host/refs/heads/main/setup.sh
   ```

2. Make script executable

   ```bash
    chmod +x setup.sh
   ```

3. Execute script

   ```
   sudo ./setup.sh
   ```

   During script execution, you'll be prompted to enter some details:

   - **Enter your domain:** Enter the domain name you want to access the supabase dashboard on. This is the host caddy server will listen for.
     For example:

     `https://supabase.example.com`

     Make sure to specify the `http/https` protocol

     > If you only want to access the dashboard locally, enter `http://localhost`. Make sure port 80 is not being used by some other app.

   - **Enter supabase dashboard username:** Provide the username you want to use for accessing the Supabase dashboard.

   - **Enter supabase dashboard password:** Set a secure password for accessing the dashboard

   - **Do you want to send confirmation emails to register users?:** Answer `[y/n]` based on your preference.

     - If you choose "yes", You'll need to set up your own SMTP server and enter the config in `.env` file. You can read more about it [here](https://supabase.com/docs/guides/self-hosting/docker#configuring-an-email-server).

     - If you choose "no", then users will be able to signup with their email & password without any email verification.

After script completes successfully, cd into `supabase/docker` directory and run `docker compose up -d`. Wait for containers to be healthy and you're good to go. To access dashboard outside your network, make sure that your firewall allows traffic on port 80 and 443. I'd recommend to not use ufw as ports exposed by docker containers bypass firewall rules. Read more about it [Here](https://docs.docker.com/engine/install/ubuntu/#firewall-limitations).

## Where to ask for help?

Stop by my [Discord server](https://discord.gg/Pbpm7NsVjG) anytime.

## Contributions

Feel free to open issues or submit pull requests if you have suggestions or improvements.
