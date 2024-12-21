import requests
import json
import os
import io
import datetime
from difflib import HtmlDiff, unified_diff
from typing import List
import glob
import htmlmin
from bs4 import BeautifulSoup
from github import Github, Repository, ContentFile

skip = ["README.md", ".gitignore"]


def download(c: ContentFile, out: str):
    filename = os.path.basename(c.download_url)
    if filename in skip:
        return print(f"Skipping {filename}")

    try:
        r = requests.get(c.download_url)

        output_path = f"{out}/{c.path}"

        os.makedirs(os.path.dirname(output_path), exist_ok=True)

        with open(output_path, "wb") as f:
            try:
                print(f"downloading {c.path} to {out}")
                f.write(r.content)
            except Exception as err:
                print(f"Error writing file {filename} {err}")
    except requests.exceptions.HTTPError as err:
        print(f"Error downloading {filename}: {err}")


def download_folder(repo: Repository, folder: str, out: str, recursive: bool):
    contents = repo.get_contents(folder)
    for c in contents:
        if c.download_url is None:
            if recursive:
                download_folder(repo, c.path, out, recursive)
            continue
        download(c, out)


def download_file(repo: Repository, folder: str, out: str):
    c = repo.get_contents(folder)
    download(c, out)


def get_files(filePath: str, list: List[str]):
    for item in glob.glob(f"{filePath}/*"):
        if os.path.isfile(item):
            list.append(item)
        elif os.path.isdir(item):
            get_files(os.path.join(filePath, item), list)


if __name__ == "__main__":
    discord_webhook_url = os.environ.get("DISCORD_WEBHOOK_URL")

    if discord_webhook_url is None:
        raise SystemExit(
            "Error: DISCORD_WEBHOOK_URL env var not present",
        )

    current_dir = os.path.dirname(os.path.abspath(__file__))
    out = os.path.join(current_dir, "remote")

    g = Github()
    repo = g.get_repo("supabase/supabase")
    download_folder(repo, folder="docker", out=out, recursive=True)

    local_docker_dir = os.path.normpath(os.path.join(current_dir, "../docker"))
    remote_docker_dir = os.path.join(out, "docker")
    remote_files: List[str] = []

    get_files(remote_docker_dir, remote_files)

    extra_files: List[str] = []

    html_head = ""
    html_body = ""

    for remote_file_path in remote_files:
        with open(remote_file_path, "r") as remote_file:
            try:
                local_file_path = (
                    local_docker_dir
                    + remote_file_path.split(
                        "docker", maxsplit=1
                    ).pop()  # -> /dev/data.sql
                )

                if not os.path.isfile(local_file_path):
                    extra_files.append(remote_file_path)
                    continue

                with open(local_file_path, "r") as local_file:
                    local_lines = local_file.read().splitlines()
                    remote_lines = remote_file.read().splitlines()

                    diff_list = list(
                        unified_diff(
                            local_lines,
                            remote_lines,
                        )
                    )

                    if len(diff_list) == 0:
                        continue

                    fileName = os.path.basename(local_file_path)

                    d = HtmlDiff()

                    html_diff = d.make_file(
                        local_lines,
                        remote_lines,
                        fromdesc=f"{fileName} Local File",
                        todesc=f"{fileName} Remote File",
                    )
                    soup = BeautifulSoup(html_diff, "html.parser")

                    if len(html_head) == 0:
                        html_head = soup.find("head").decode_contents()

                    html_body += soup.find("body").decode_contents()
            except Exception as err:
                print(err)

    if len(html_body) == 0:
        html_diff = "<html><body><h1>No changes!</h1></body></html>"
    else:
        html_diff = f"""
        <html>
        {html_head}
        <body>
        {"" if len(extra_files) == 0 else f"<h1>extraFiles={str(extra_files)}</h1><br>"}
        {html_body}
        </body>
        </html>
        """

    report_date = datetime.datetime.now().strftime("%d-%m-%Y")

    file = io.StringIO(htmlmin.minify(html_diff, remove_empty_space=True))
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
    except Exception as err:
        raise SystemExit(f"Error: {err}")
    finally:
        file.close()
