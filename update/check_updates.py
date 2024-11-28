import requests
import yaml
import json
import os


def parse_yaml(file):
    return yaml.safe_load(file)


def extract_image_tags(data: dict):
    extracted = {}
    services = data["services"]
    for key in services:
        extracted[key] = services[key]["image"]

    return extracted


def send_webhook(url: str, description: str):
    try:
        res = requests.post(
            url,
            json={
                "content": "",
                "embeds": [
                    {
                        "title": "Report",
                        "description": description,
                    }
                ],
            },
        )

        res.raise_for_status()
    except requests.exceptions.HTTPError as err:
        raise SystemExit(err)


if __name__ == "__main__":
    discord_webhook_url = os.environ.get("DISCORD_WEBHOOK_URL")

    if discord_webhook_url is None:
        raise SystemExit(
            "Error: discord_webhook_url env var not present",
        )

    with open("docker/docker-compose.yml") as stream:
        try:
            local_img_tags = extract_image_tags(parse_yaml(stream))

            response = requests.get(
                "https://raw.githubusercontent.com/supabase/supabase/refs/heads/master/docker/docker-compose.yml"
            )

            remote_img_tags = extract_image_tags(parse_yaml(response.text))

            extra_services, upgradable = [], []

            # one extra in local is caddy
            if abs(len(remote_img_tags) - len(local_img_tags)) > 1:
                for key in remote_img_tags:
                    if key not in local_img_tags:
                        extra_services.append(key)

            for key in local_img_tags:
                if key == "caddy":
                    continue

                if local_img_tags[key] != remote_img_tags[key]:
                    upgradable.append(key)

            send_webhook(
                discord_webhook_url,
                json.dumps(
                    {
                        "extra_services": extra_services,
                        "upgradable": upgradable,
                    },
                    indent=0,
                ),
            )
        except yaml.YAMLError as err:
            raise SystemExit(f"Error parsing yaml: {err}")
        except Exception as err:
            raise SystemExit(f"Error: {err}")
