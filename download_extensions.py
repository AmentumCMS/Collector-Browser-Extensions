import requests
import os
import re

def download_extension(extension_url):
    chrome_patterns = [
        r"https://chrome\.google\.com/webstore/detail/.+/([a-z]{32})",
        r"https://chromewebstore\.google\.com/detail/.+/([a-z]{32})"
    ]
    edge_pattern = r"https://microsoftedge\.microsoft\.com/addons/detail/.+/([a-z]{32})"

    extension_id = None
    browser = None

    for pattern in chrome_patterns:
        match = re.match(pattern, extension_url)
        if match:
            extension_id = match.group(1)
            browser = 'chrome'
            break

    if not extension_id:
        match = re.match(edge_pattern, extension_url)
        if match:
            extension_id = match.group(1)
            browser = 'edge'

    if not extension_id or not browser:
        print(f"[ERROR] Invalid URL format: {extension_url}")
        return

    if browser == 'chrome':
        url = f"https://clients2.google.com/service/update2/crx?response=redirect&prodversion=49.0&x=id%3D{extension_id}%26installsource%3Dondemand%26uc"
    else:
        url = f"https://edge.microsoft.com/extensionwebstorebase/v1/crx?response=redirect&prodversion=49.0&x=id%3D{extension_id}%26installsource%3Dondemand%26uc"

    print(f"[INFO] Fetching CRX for {browser} extension ID {extension_id}")
    print(f"[DEBUG] Download URL: {url}")

    try:
        response = requests.get(url)
        print(f"[DEBUG] HTTP Status Code: {response.status_code}")
        if response.status_code == 200:
            version = response.headers.get('x-cws-version', 'latest')
            filename = f"{browser}_{extension_id}_{version}.crx"
            file_path = os.path.join("extensions", filename)
            with open(file_path, "wb") as file:
                file.write(response.content)
            print(f"[SUCCESS] Downloaded {filename} to {file_path}")
        else:
            print(f"[ERROR] Failed to download extension. Status code: {response.status_code}")
    except Exception as e:
        print(f"[EXCEPTION] Error occurred while downloading: {e}")

def main():
    os.makedirs("extensions", exist_ok=True)

    try:
        with open('extensions_list.txt', 'r') as file:
            lines = file.readlines()
    except FileNotFoundError:
        print("[ERROR] extensions_list.txt not found.")
        return

    for line in lines:
        line = line.strip()
        if line:
            print(f"[INFO] Processing URL: {line}")
            download_extension(line)

if __name__ == "__main__":
    main()
