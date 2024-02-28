#!/bin/bash
#
# Copyright (c) 2020-2024, NVIDIA CORPORATION. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

set -ex

SCALA_BINARY_VER=${SCALA_BINARY_VER:-"2.12"}
if [ $SCALA_BINARY_VER == "2.13" ]; then
    cd scala2.13
    ln -sf ../jenkins jenkins
fi

. jenkins/version-def.sh

WORKSPACE=${WORKSPACE:-$(pwd)}
## export 'M2DIR' so that shims can get the correct Spark dependency info
export M2DIR=${M2DIR:-"$WORKSPACE/.m2"}
export URM_URL=${URM_URL}

mvn --version

## MVN_OPT : maven options environment, e.g. MVN_OPT='-Dspark-rapids-jni.version=xxx' to specify spark-rapids-jni dependency's version.
export MVN="mvn -Dmaven.wagon.http.retryHandler.count=3 -DretryFailedDeploymentCount=3 ${MVN_OPT} -Psource-javadoc"
export MVN_URM_MIRROR=${MVN_URM_MIRROR}

export DIST_PL="dist"
function mvnEval {
    $MVN help:evaluate -q -pl $DIST_PL $MVN_URM_MIRROR -Prelease311 -Dmaven.repo.local=$M2DIR -DforceStdout -Dexpression=$1
}

export ART_ID=$(mvnEval project.artifactId)
export ART_GROUP_ID=$(mvnEval project.groupId)
export ART_VER=$(mvnEval project.version)
export DEFAULT_CUDA_CLASSIFIER=${DEFAULT_CUDA_CLASSIFIER:-$(mvnEval cuda.version)} # default cuda version
CUDA_CLASSIFIERS=${CUDA_CLASSIFIERS:-"$DEFAULT_CUDA_CLASSIFIER"} # e.g. cuda11,cuda12
export CLASSIFIERS=${CLASSIFIERS:-"$CUDA_CLASSIFIERS"}  # default as CUDA_CLASSIFIERS for compatibility
IFS=',' read -a CLASSIFIERS_ARR <<< "$CLASSIFIERS"
export TMP_PATH="/tmp/$(date '+%Y-%m-%d')-$$"

export DIST_FPATH="$DIST_PL/target/sparkbuildver/$ART_ID-$ART_VER-$DEFAULT_CUDA_CLASSIFIER"
export DIST_POM_FPATH="$DIST_PL/target/sparkbuildver/parallel-world/META-INF/maven/$ART_GROUP_ID/$ART_ID/pom.xml"

DIST_PROFILE_OPT=-Dincluded_buildvers=$(IFS=,; echo "${SPARK_SHIM_VERSIONS[*]}")
DIST_INCLUDES_DATABRICKS=${DIST_INCLUDES_DATABRICKS:-"true"}
if [[ "$DIST_INCLUDES_DATABRICKS" == "true" ]] && [[ -n ${SPARK_SHIM_VERSIONS_DATABRICKS[*]} ]] && [[ "$SCALA_BINARY_VER" == "2.12" ]]; then
    DIST_PROFILE_OPT="$DIST_PROFILE_OPT,"$(IFS=,; echo "${SPARK_SHIM_VERSIONS_DATABRICKS[*]}")
fi

export DEPLOY_TYPES='jar'
export DEPLOY_FILES="${DIST_FPATH}.jar"
export DEPLOY_CLASSIFIERS="$DEFAULT_CUDA_CLASSIFIER"
# Make sure that the local m2 repo on the build machine has the same pom
# installed as the one being pushed to the remote repo. This to prevent
# discrepancies between the build machines regardless of how the local repo was populated.
function distWithReducedPom {
    cmd="$1"
    buildver="$2"
    IFS=',' read -a classifiers_arr <<< "$CLASSIFIERS"

    case $cmd in

        install)
            mvnCmd="install:install-file"
            mvnExtraFlags="-Dpackaging=jar"
            ;;

        deploy)
            mvnCmd="deploy:deploy-file"
            if (( ${#classifiers_arr[@]} > 1 )); then
              # try move tmp artifacts back to target folder for simplifying separate release process
              mv ${TMP_PATH}/${ART_ID}-${ART_VER}-*.jar ${DIST_PL}/target/spark${SPARK_BASE_SHIM_VERSION}/
            fi
            mvnExtraFlags="-Durl=${URM_URL}-local -DrepositoryId=snapshots -Dtypes=${DEPLOY_TYPES} -Dfiles=${DEPLOY_FILES/buildver/$buildver} -Dclassifiers=${DEPLOY_CLASSIFIERS}"
            ;;

        *)
            echo "Unknown command: $cmd"
            ;;
    esac

    $MVN -B $mvnCmd $MVN_URM_MIRROR \
        -Dcuda.version=$DEFAULT_CUDA_CLASSIFIER \
        -Dmaven.repo.local=$M2DIR \
        -Dfile="${DIST_FPATH/buildver/$buildver}.jar" \
        -DpomFile="${DIST_POM_FPATH/buildver/$buildver}" \
        -DgroupId="${ART_GROUP_ID}" \
        -DartifactId="${ART_ID}" \
        -Dversion="${ART_VER}" \
        -Dtarget.classifier="spark$buildver" \
        $mvnExtraFlags
}

# build, install, and deploy all the versions we support, but skip deploy of individual dist module since we
# only want the combined jar to be pushed.
# Note this does not run any integration tests
# Deploy jars unless SKIP_DEPLOY is 'true'

# option to skip unit tests. Used in our CI to separate test runs in parallel stages
export SKIP_TESTS=${SKIP_TESTS:-"false"}
export SKIP_DEPLOY=${SKIP_DEPLOY:-"true"}

export BUILD_LOG_DIR='/tmp/shim_build'
mkdir -p $BUILD_LOG_DIR

BUILD_PARALLEL=${BUILD_PARALLEL:-4}

set +H # turn off history expansion
export DEPLOY_SUBMODULES=${DEPLOY_SUBMODULES:-"!${DIST_PL}"} # TODO: deploy only required submodules to save time

function buildSingleShim {
    set -ex
    local buildver="$1"
    local LOCK_FACTORY="file-lock"
    local NAME_MAPPER="file-gav"

    $MVN -U -B clean install $MVN_URM_MIRROR -Dmaven.repo.local=$M2DIR \
        -Dcuda.version=$DEFAULT_CUDA_CLASSIFIER \
        -DskipTests=$SKIP_TESTS \
        -Dbuildver="${buildver}" \
        -Dtarget.classifier="spark$buildver" \
        -Dorg.slf4j.simpleLogger.showThreadName=true -Dorg.slf4j.simpleLogger.showDateTime=true \
        -Dorg.slf4j.simpleLogger.log.org.eclipse.aether=trace -l /tmp/shim_build/$LOCK_FACTORY-$NAME_MAPPER-$buildver.log \
        -Daether.connector.basic.threads=8 -Daether.metadataResolver.threads=8 \
        -Daether.syncContext.named.time=120 \
        -Daether.syncContext.named.factory=$LOCK_FACTORY -Daether.syncContext.named.nameMapper=$NAME_MAPPER;

    if [[ $SKIP_TESTS == "false" ]]; then
      # Run filecache tests
      SPARK_CONF=spark.rapids.filecache.enabled=true \
          $MVN -B test -rf tests $MVN_URM_MIRROR -Dmaven.repo.local=$M2DIR \
              -Dcuda.version=$DEFAULT_CUDA_CLASSIFIER \
              -Dbuildver="${buildver}" \
              -DwildcardSuites=org.apache.spark.sql.rapids.filecache.FileCacheIntegrationSuite \
              -Dtarget.classifier="spark$buildver"
    fi
    distWithReducedPom "install" $buildver
    # if [[ $SKIP_DEPLOY != 'true' ]]; then
    #     # this deploys selected submodules
    #     $MVN -B deploy -pl $DEPLOY_SUBMODULES $MVN_URM_MIRROR \
    #         -Dmaven.repo.local=$M2DIR \
    #         -Dcuda.version=$DEFAULT_CUDA_CLASSIFIER \
    #         -DskipTests \
    #         -Dmaven.scaladoc.skip -Dmaven.scalastyle.skip=true \
    #         -Dbuildver="${buildver}" \
    #         -Dtarget.classifier="spark$buildver" 
    # fi
}

function checkFailure {
    set +x

    local buildver=$2
    local buildLog="${BUILD_LOG_DIR}/build${buildver}.log"
    local fileLockLog="${BUILD_LOG_DIR}/file-lock-file-gav-$buildver.log "

    $("$@" > $buildLog 2>&1)

    local status=$?
    echo $status
    cat $fileLockLog
    cat $buildLog

    if [[ $status == 0 ]]; then
        echo "Shim${buildver} build completed."
    else
        echo "Failed to build shim${buildver}."
        exit 255
    fi
}

export -f buildSingleShim checkFailure distWithReducedPom

# Parallelly build shims
for ((i=1; i<${#SPARK_SHIM_VERSIONS[@]}; i+=$BUILD_PARALLEL)); do
    printf "%s\n" "${SPARK_SHIM_VERSIONS[@]:i:$BUILD_PARALLEL}" | \
        xargs -t -I% -P "$BUILD_PARALLEL" -n 1 \
        bash -c 'checkFailure buildSingleShim "$@"' _ %
done

installDistArtifact() {
  local cuda_version="$1"
  local opt="$2"
  $MVN -B clean install \
      $opt \
      $DIST_PROFILE_OPT \
      -Dbuildver=$SPARK_BASE_SHIM_VERSION \
      $MVN_URM_MIRROR \
      -Dmaven.repo.local=$M2DIR \
      -Dcuda.version=$cuda_version \
      -DskipTests=$SKIP_TESTS \
      -Dtarget.classifier="spark$SPARK_BASE_SHIM_VERSION" 
}

# build extra cuda classifiers
if (( ${#CLASSIFIERS_ARR[@]} > 1 )); then
  mkdir -p ${TMP_PATH}
  for classifier in "${CLASSIFIERS_ARR[@]}"; do
    if [ "${classifier}" == "${DEFAULT_CUDA_CLASSIFIER}" ]; then
      echo "skip default: ${DEFAULT_CUDA_CLASSIFIER} in build extra cuda classifiers step..."
      continue
    fi

    opt=""
    if [[ "${classifier}" == *"-arm64" ]]; then
      opt="-Parm64"
    fi
    # pass cuda version and extra opt
    installDistArtifact ${classifier%%-*} ${opt}

    # move artifacts to temp for deployment later
    artifactFile="${ART_ID}-${ART_VER}-${classifier}.jar"
    mv ${DIST_PL}/target/spark${SPARK_BASE_SHIM_VERSION}/${artifactFile} ${TMP_PATH}/
    # update deployment properties
    DEPLOY_TYPES="${DEPLOY_TYPES},jar"
    DEPLOY_FILES="${DEPLOY_FILES},${DIST_PL}/target/spark${SPARK_BASE_SHIM_VERSION}/${artifactFile}"
    DEPLOY_CLASSIFIERS="${DEPLOY_CLASSIFIERS},${classifier}"
  done
fi
# build dist w/ default cuda classifier
# installDistArtifact ${DEFAULT_CUDA_CLASSIFIER}

# distWithReducedPom "install" $SPARK_BASE_SHIM_VERSION

# if [[ $SKIP_DEPLOY != 'true' ]]; then
#     distWithReducedPom "deploy" $SPARK_BASE_SHIM_VERSION

#     # this deploys selected submodules that is unconditionally built with Spark 3.1.1
#     $MVN -B deploy -pl $DEPLOY_SUBMODULES \
#         -Dbuildver=$SPARK_BASE_SHIM_VERSION \
#         -DskipTests \
#         -Dmaven.scaladoc.skip -Dmaven.scalastyle.skip=true \
#         $MVN_URM_MIRROR -Dmaven.repo.local=$M2DIR \
#         -Dcuda.version=$DEFAULT_CUDA_CLASSIFIER \
#         -Dtarget.classifier="spark$SPARK_BASE_SHIM_VERSION" 
# fi

# Parse Spark files from local mvn repo
jenkins/printJarVersion.sh "SPARKVersion" "$M2DIR/org/apache/spark/spark-core_2.12/${SPARK_VER}" "spark-core_2.12-${SPARK_VER}" ".jar" $SERVER_ID
