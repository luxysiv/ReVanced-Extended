#!/bin/bash

basename() {
    sed 's/.*\///' | sed 's/\.[^.]*$//'
}

req() {
    wget -nv -O "$2" --header="Authorization: token $accessToken" "$1"
}

download_repository_assets() {
    local repoName=$1
    local repoUrl=$2
    local repoApiUrl="https://api.github.com/repos/$repoUrl/releases/latest"
    local response=$(req "$repoApiUrl" - 2>/dev/null)

    local assetUrls=$(echo "$response" | jq -r --arg repoName "$repoName" '.assets[] | select(.name | contains($repoName)) | .browser_download_url, .name')

    while read -r downloadUrl && read -r assetName; do
        req "$downloadUrl" "$assetName"
    done <<< "$assetUrls"
}

download_youtube_apk() {
    package_info=$(java -jar revanced-cli*.jar list-versions -f com.google.android.youtube revanced-patches*.jar)    
    version=$(echo "$package_info" | grep -oP '\d+(\.\d+)+' | sort -ur | sed -n '1p')
    chmod +x dl_yt && ./dl_yt $version
}

apply_patches() {
    version=$1
    
    # Read patches from file
    mapfile -t lines < ./patches.txt

    # Process patches
    for line in "${lines[@]}"; do
        if [[ -n "$line" && ( ${line:0:1} == "+" || ${line:0:1} == "-" ) ]]; then
            patch_name=$(sed -e 's/^[+|-] *//;s/ *$//' <<< "$line") 
            [[ ${line:0:1} == "+" ]] && includePatches+=("--include" "$patch_name")
            [[ ${line:0:1} == "-" ]] && excludePatches+=("--exclude" "$patch_name")
        fi
    done

    java -jar revanced-cli.jar -h

    # Apply patches using Revanced tools
    java -jar revanced-cli*.jar patch \
        --merge revanced-integrations*.apk \
        --patch-bundle revanced-patches*.jar \
        "${excludePatches[@]}" "${includePatches[@]}" \
        --out "patched-youtube-v$version.apk" \
        "youtube-v$version.apk"
}

sign_patched_apk() {
    version=$1
    
    # Sign the patched APK
    apksigner=$(find $ANDROID_SDK_ROOT/build-tools -name apksigner -type f | sort -r | head -n 1)
    $apksigner sign --ks public.jks \
        --ks-key-alias public \
        --ks-pass pass:public \
        --key-pass pass:public \
        --in "patched-youtube-v$version.apk" \
        --out "youtube-revanced-extended-v$version.apk"
}

create_github_release() {
    local accessToken="$1"
    local repoOwner="$2"
    local repoName="$3"

    local tagName=$(date +"%d-%m-%Y")
    local patchFilePath=$(find . -type f -name "revanced-patches*.jar")
    local apkFilePath=$(find . -type f -name "youtube-revanced*.apk")
    local patchFileName=$(echo "$patchFilePath" | basename)
    local apkFileName=$(echo "$apkFilePath" | basename).apk

    # Only release with APK file
    if [ ! -f "$apkFilePath" ]; then
        exit
    fi

    # Check if the release with the same tag already exists
    local existingRelease=$(wget -qO- --header="Authorization: token $accessToken" "https://api.github.com/repos/$repoOwner/$repoName/releases/tags/$tagName")

    if [ -n "$existingRelease" ]; then
        local existingReleaseId=$(echo "$existingRelease" | jq -r ".id")

        # If the release exists, delete it
        wget -q --method=DELETE --header="Authorization: token $accessToken" "https://api.github.com/repos/$repoOwner/$repoName/releases/$existingReleaseId" -O /dev/null
    fi

    # Create a new release
    local releaseData='{
        "tag_name": "'"$tagName"'",
        "target_commitish": "main",
        "name": "Release '"$tagName"'",
        "body": "'"$patchFileName"'"
    }'
    local newRelease=$(wget -qO- --post-data="$releaseData" --header="Authorization: token $accessToken" --header="Content-Type: application/json" "https://api.github.com/repos/$repoOwner/$repoName/releases")
    local releaseId=$(echo "$newRelease" | jq -r ".id")

    # Upload APK file
    local uploadUrlApk="https://uploads.github.com/repos/$repoOwner/$repoName/releases/$releaseId/assets?name=$apkFileName"
    wget -q --header="Authorization: token $accessToken" --header="Content-Type: application/zip" --post-file="$apkFilePath" -O /dev/null "$uploadUrlApk"
}

check_release_body() {
    scriptRepoBody=$1
    downloadedPatchFileName=$2

    # Compare body content with downloaded patch file name
    if [ "$scriptRepoBody" != "$downloadedPatchFileName" ]; then
        return 0
    else
        return 1
    fi
}
