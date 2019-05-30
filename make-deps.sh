#!/bin/bash

# determine the root directory of the package repo

REPO_DIR=$(cd $(dirname ${BASH_SOURCE[0]}) && pwd)
if [ ! -d  "${REPO_DIR}/.git" ]; then
    2>&1 echo "${REPO_DIR} is not a git repository"
    exit 1
fi

# the first and the only argument should be the version of flink

NAME=$(basename ${BASH_SOURCE[0]})
if [ $# -ne 1 ]; then
    2>&1 cat <<EOF
Usage: $NAME <flink version>
EOF
    exit 2
fi

FLINK_VERSION=$1

### move previous repository temporarily

if [ -d ${HOME}/.m2/repository ]; then
    mv ${HOME}/.m2/repository ${HOME}/.m2/repository.backup.$$
fi

### fetch the flink sources and unpack

FLINK_TGZ=flink-${FLINK_VERSION}-src.tar.gz

if [ ! -f "${flink_TGZ}" ]; then
    FLINK_URL=http://github.com/apache/flink/archive/release-${FLINK_VERSION}.tar.gz
    if ! curl -L -o "${FLINK_TGZ}" "${FLINK_URL}"; then
        2>&1 echo Failed to download sources: $FLINK_URL
        exit 1
    fi
fi

cd "${REPO_DIR}"

# assume all the files go to a subdir (so any file will give us the directory
# it's extracted to)
FLINK_DIR=$(tar xzvf "${FLINK_TGZ}" | head -1)
FLINK_DIR=${FLINK_DIR%%/*}
tar xzf "${FLINK_TGZ}"

### fetch the FLINK depenencies and store the log (to retrieve the urls)

cd "${FLINK_DIR}"

#patch it as per the flink .spec (assume files do not contain spaces)

PATCHES=$(grep ^Patch "${REPO_DIR}/../apache-flink/apache-flink.spec" 2>/dev/null \
	| sed -e 's/Patch[0-9]\+\s*:\s*\(\S\)\s*/\1/')

for p in $PATCHES; do
    patch -p1 < "${REPO_DIR}/../apache-flink/${p}"
done

mvn package -Pnative -Pdist -DskipTests -Dtar | sed -e 's//\n/g'  > flink.build.out || exit 1

cd "${REPO_DIR}"

# remove previously created artifacts
rm -f sources.txt install.txt files.txt metadata-*.patch

### make the list of the dependencies
DEPENDENCIES=($(grep '^Downloaded' "${FLINK_DIR}/flink.build.out" | sed -e\
    's/^Downloaded.\+:\s//' | uniq))

### create pieces of the spec (SourceXXX definitions and their install actions)

# some of the maven repositories do not allow direct download, so use single
# repository instead: https://repo1.maven.org/maven2/ . It the same as
# https://central.maven.org, but central.maven.org uses bad certificate (FQDN
# mismatch).
REPOSITORY_URLS=(
                https://repo.maven.apache.org/maven2/
                http://packages.confluent.io/maven/
                http://repository.mapr.com/maven/
                )

# flink specifically has some basename clashes which results download conflicts
# when used in .spec as-is. keep track of these files to name them differently.
declare -A FILE_MAP
SOURCES_SECTION=""
INSTALL_SECTION=""
FILES_SECTION=""
warn=
n=0

for dep in ${DEPENDENCIES[@]}; do
    dep_bn=$(basename "$dep")
    dep_sfx=""
    dep_url=""
    if [ -n "${FILE_MAP[${dep_bn}]}" ]; then
        let dep_sfx=${FILE_MAP[${dep_bn}]}+1
        FILE_MAP[${dep_bn}]=${dep_sfx}
    else
        FILE_MAP[${dep_bn}]=0
    fi
    for url in ${REPOSITORY_URLS[@]}; do
        dep_path=${dep##$url}
        # if we actually removed the url, then it's a mismatch (i.e. success)
        if [ "${dep_path}" != "${dep}" ]; then
            if [ "${url}" == "https://repo.maven.apache.org/maven2/" ]; then
                dep_url="https://repo1.maven.org/maven2/${dep_path}"
            else
                dep_url="${dep}"
            fi
            dep="${dep_path}"
            break
        fi
    done
    [ -z "$dep_url" ] && continue
    dep_dn=$(dirname "${dep_path}")
    dep_fn="${dep_bn}${dep_sfx}" # downloaded filename
    if [ -n "${dep_sfx}" ]; then
        dep_url="${dep_url}"
    fi
    SOURCES_SECTION="${SOURCES_SECTION}
Source${n} : ${dep_url}"
    INSTALL_SECTION="${INSTALL_SECTION}
mkdir -p %{buildroot}/usr/share/apache-flink/.m2/repository/${dep_dn}
cp %{SOURCE${n}} %{buildroot}/usr/share/apache-flink/.m2/repository/${dep_dn}/${dep_bn}"
    FILES_SECTION="${FILES_SECTION}
/usr/share/apache-flink/.m2/repository/${dep}"
    let n=${n}+1
done

cd "${REPO_DIR}"

echo "${SOURCES_SECTION}" | sed -e '1d' > sources.txt
echo "${INSTALL_SECTION}" | sed -e '1d' > install.txt
echo "${FILES_SECTION}" | sed -e '1d' > files.txt

cat <<EOF

sources.txt     contains SourceXXXX definitions for the spec file (including
                patches for metadata).
install.txt     contains %install section.
files.txt       contains the %files section.
EOF

# restore previous .m2
rm -rf ${HOME}/.m2/repository
if [ -d ${HOME}/.m2/repository.backup.$$ ]; then
    mv ${HOME}/.m2/repository.backup.$$ ${HOME}/.m2/repository
fi

