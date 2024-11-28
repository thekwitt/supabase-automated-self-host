import requests
import json
import os
import io
import datetime
from difflib import HtmlDiff


if __name__ == "__main__":
    discord_webhook_url = os.environ.get("DISCORD_WEBHOOK_URL")

    if discord_webhook_url is None:
        raise SystemExit(
            "Error: discord_webhook_url env var not present",
        )

    current_dir = os.path.dirname(os.path.abspath(__file__))

    with open(os.path.join(current_dir, "../docker/docker-compose.yml")) as local_file:
        try:
            response = requests.get(
                "https://raw.githubusercontent.com/supabase/supabase/refs/heads/master/docker/docker-compose.yml"
            )

            d = HtmlDiff()

            html_diff = d.make_file(
                local_file.read().splitlines(),
                response.text.splitlines(),
                fromdesc="Local File",
                todesc="Remote File",
            )

            report_date = datetime.datetime.now().strftime("%d-%m-%Y")
            file = io.StringIO(html_diff)
            file.name = f"diff-{report_date}.html"

            try:
                res = requests.post(
                    discord_webhook_url,
                    data={
                        "payload_json": json.dumps(
                            {"embeds": [{"title": f"Report {report_date}"}]}
                        )
                    },
                    files={"file": file},
                )
                res.raise_for_status()
            except requests.exceptions.HTTPError as err:
                raise SystemExit(err)
            finally:
                file.close()

        except Exception as err:
            raise SystemExit(f"Error: {err}")
