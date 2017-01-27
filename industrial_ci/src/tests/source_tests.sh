#!/bin/bash

# Copyright (c) 2015, Isaac I. Y. Saito
# Copyright (c) 2017, Mathias Luedtke
# All rights reserved.
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
## Greatly inspired by JSK travis https://github.com/jsk-ros-pkg/jsk_travis

# Building in 16.04 requires running this script in a docker container
# The Dockerfile in this repository defines a Ubuntu 16.04 container
if [[ "$ROS_DISTRO" == "kinetic" ]] && ! [ "$IN_DOCKER" ]; then
  ici_time_start build_docker_image
  docker build -t industrial-ci/xenial .
  ici_time_end  # build_docker_image

  #forward ssh agent into docker container
  if [ "$SSH_AUTH_SOCK" ]; then
      export SSH_DOCKER_CMD="-v $(dirname $SSH_AUTH_SOCK):$(dirname $SSH_AUTH_SOCK) -e SSH_AUTH_SOCK=$SSH_AUTH_SOCK"
  else
      export SSH_DOCKER_CMD=""
  fi

  docker_target_repo_path=/root/ci_src
  docker_ici_pkg_path=${ICI_SRC_PATH/$TARGET_REPO_PATH/$docker_target_repo_path}
  docker create \
      --name run-industrial-ci \
      --env-file ${ICI_SRC_PATH}/docker.env \
      -e TARGET_REPO_PATH=$docker_target_repo_path \
      $SSH_DOCKER_CMD \
      -v $TARGET_REPO_PATH/:$docker_target_repo_path industrial-ci/xenial \
      /bin/bash -c "cd $docker_ici_pkg_path; source ./ci_main.sh;"
  docker cp ~/.ssh run-industrial-ci:/root/ # pass SSH settings to container
  docker start -a run-industrial-ci
  unset AFTER_SCRIPT # do not run AFTER_SCRIPT again
  return
 fi

#Define some verbose env vars
if [ "$VERBOSE_OUTPUT" ] && [ "$VERBOSE_OUTPUT" == true ]; then
    OPT_VI="-vi"
else
    OPT_VI=""
fi

ici_time_start init_ici_environment
# Define more env vars
BUILDER=catkin
ROSWS=wstool

if [ ! "$CATKIN_PARALLEL_JOBS" ]; then export CATKIN_PARALLEL_JOBS="-p4"; fi
if [ ! "$CATKIN_PARALLEL_TEST_JOBS" ]; then export CATKIN_PARALLEL_TEST_JOBS="$CATKIN_PARALLEL_JOBS"; fi
if [ ! "$ROS_PARALLEL_JOBS" ]; then export ROS_PARALLEL_JOBS="-j8"; fi
if [ ! "$ROS_PARALLEL_TEST_JOBS" ]; then export ROS_PARALLEL_TEST_JOBS="$ROS_PARALLEL_JOBS"; fi
# If not specified, use ROS Shadow repository http://wiki.ros.org/ShadowRepository
if [ ! "$ROS_REPOSITORY_PATH" ]; then export ROS_REPOSITORY_PATH="http://packages.ros.org/ros-shadow-fixed/ubuntu"; fi
# .rosintall file name
if [ ! "$ROSINSTALL_FILENAME" ]; then export ROSINSTALL_FILENAME=".travis.rosinstall"; fi
# For apt key stores
if [ ! "$APTKEY_STORE_HTTPS" ]; then export APTKEY_STORE_HTTPS="https://raw.githubusercontent.com/ros/rosdistro/master/ros.key"; fi
if [ ! "$APTKEY_STORE_SKS" ]; then export APTKEY_STORE_SKS="hkp://ha.pool.sks-keyservers.net"; fi  # Export a variable for SKS URL for break-testing purpose.
if [ ! "$HASHKEY_SKS" ]; then export HASHKEY_SKS="0xB01FA116"; fi
if [ "$USE_DEB" ]; then  # USE_DEB is deprecated. See https://github.com/ros-industrial/industrial_ci/pull/47#discussion_r64882878 for the discussion.
    if [ "$USE_DEB" != "true" ]; then export UPSTREAM_WORKSPACE="file";
    else export UPSTREAM_WORKSPACE="debian";
    fi
fi
if [ ! "$UPSTREAM_WORKSPACE" ]; then export UPSTREAM_WORKSPACE="debian"; fi

ici_time_end  # init_ici_environment

ici_time_start setup_ros

# Set apt repo
lsb_release -a
sudo -E sh -c 'echo "deb $ROS_REPOSITORY_PATH `lsb_release -cs` main" > /etc/apt/sources.list.d/ros-latest.list'
# Common ROS install preparation
# apt key acquisition. Since keyserver may often become accessible, backup method is added.
sudo apt-key adv --keyserver $APTKEY_STORE_SKS --recv-key $HASHKEY_SKS  \
    || { echo 'Fetching apt key from SKS keyserver somehow failed. Trying to get one from alternative.\n'; wget $APTKEY_STORE_HTTPS -O - | sudo apt-key add -; } \
    || error 'Fetching apt key by an alternative method failed too. Exiting since ROS cannot be installed.'

sudo apt-get -qq update || error "ERROR: apt server not responding. This is a rare situation, and usually just waiting for a while clears this. See https://github.com/ros-industrial/industrial_ci/pull/56 for more of the discussion"
 
sudo apt-get -qq install --no-install-recommends -y build-essential python-catkin-tools python-rosdep python-wstool ros-$ROS_DISTRO-catkin ssh-client

# If more DEBs needed during preparation, define ADDITIONAL_DEBS variable where you list the name of DEB(S, delimitted by whitespace)
if [ "$ADDITIONAL_DEBS" ]; then
    sudo apt-get install -q -qq -y $ADDITIONAL_DEBS || error "One or more additional deb installation is failed. Exiting."
fi
source /opt/ros/$ROS_DISTRO/setup.bash

ici_time_end  # setup_ros

ici_time_start setup_rosdep

# Setup rosdep
pip --version
rosdep --version
sudo rosdep init
ret_rosdep=1
rosdep update || while [ $ret_rosdep != 0 ]; do sleep 1; rosdep update && ret_rosdep=0 || echo "rosdep update failed"; done

ici_time_end  # setup_rosdep

ici_time_start setup_rosws

## BEGIN: travis' install: # Use this to install any prerequisites or dependencies necessary to run your build ##
# Create workspace
CATKIN_WORKSPACE=~/catkin_ws
mkdir -p $CATKIN_WORKSPACE/src
cd $CATKIN_WORKSPACE/src
$ROSWS init .
case "$UPSTREAM_WORKSPACE" in
debian)
    echo "Obtain deb binary for upstream packages."
    ;;
file) # When UPSTREAM_WORKSPACE is file, the dependended packages that need to be built from source are downloaded based on $ROSINSTALL_FILENAME file.
    # Prioritize $ROSINSTALL_FILENAME.$ROS_DISTRO if it exists over $ROSINSTALL_FILENAME.
    if [ -e $TARGET_REPO_PATH/$ROSINSTALL_FILENAME.$ROS_DISTRO ]; then
        # install (maybe unreleased version) dependencies from source for specific ros version
        $ROSWS merge file://$TARGET_REPO_PATH/$ROSINSTALL_FILENAME.$ROS_DISTRO
    elif [ -e $TARGET_REPO_PATH/$ROSINSTALL_FILENAME ]; then
        # install (maybe unreleased version) dependencies from source
        $ROSWS merge file://$TARGET_REPO_PATH/$ROSINSTALL_FILENAME
    fi
    ;;
http://* | https://*) # When UPSTREAM_WORKSPACE is an http url, use it directly
    $ROSWS merge $UPSTREAM_WORKSPACE
    ;;
esac

# download upstream packages into workspace
if [ -e .rosinstall ]; then
    # ensure that the downstream is not in .rosinstall
    $ROSWS rm $TARGET_REPO_NAME || true
    $ROSWS update
fi
# TARGET_REPO_PATH is the path of the downstream repository that we are testing. Link it to the catkin workspace
ln -s $TARGET_REPO_PATH .

if [ "${USE_MOCKUP// }" != "" ]; then
    if [ ! -d "$TARGET_REPO_PATH/$USE_MOCKUP" ]; then
        error "mockup directory '$USE_MOCKUP' does not exist"
    fi
    ln -s "$TARGET_REPO_PATH/$USE_MOCKUP" .
fi

ici_time_end  # setup_rosws

ici_time_start before_script


# execute BEFORE_SCRIPT in repository, exit on errors
cd $TARGET_REPO_PATH
if [ "${BEFORE_SCRIPT// }" != "" ]; then sh -e -c "${BEFORE_SCRIPT}"; fi

ici_time_end  # before_script

ici_time_start rosdep_install

sudo rosdep install -q --from-paths $CATKIN_WORKSPACE --ignore-src --rosdistro $ROS_DISTRO -y
ici_time_end  # rosdep_install

ici_time_start catkin_build

cd $CATKIN_WORKSPACE

# for catkin
if [ "${TARGET_PKGS// }" == "" ]; then export TARGET_PKGS=`catkin_topological_order ${TARGET_REPO_PATH} --only-names`; fi
if [ "${PKGS_DOWNSTREAM// }" == "" ]; then export PKGS_DOWNSTREAM=$( [ "${BUILD_PKGS_WHITELIST// }" == "" ] && echo "$TARGET_PKGS" || echo "$BUILD_PKGS_WHITELIST"); fi
if [ "$BUILDER" == catkin ]; then catkin build $OPT_VI --summarize  --no-status $BUILD_PKGS_WHITELIST $CATKIN_PARALLEL_JOBS --make-args $ROS_PARALLEL_JOBS            ; fi

ici_time_end  # catkin_build

if [ "$NOT_TEST_BUILD" != "true" ]; then
    ici_time_start catkin_run_tests

    if [ "$BUILDER" == catkin ]; then
        source devel/setup.bash # force to update ROS_PACKAGE_PATH for rostest
        catkin run_tests $OPT_VI --no-deps --no-status $PKGS_DOWNSTREAM $CATKIN_PARALLEL_TEST_JOBS --make-args $ROS_PARALLEL_TEST_JOBS --
        catkin_test_results build || error
    fi

    ici_time_end  # catkin_run_tests
fi


if [ "$NOT_TEST_INSTALL" != "true" ]; then

    ici_time_start catkin_install_build

    # Test if the packages in the downstream repo build.
    if [ "$BUILDER" == catkin ]; then
        catkin clean --yes
        catkin config --install
        catkin build $OPT_VI --summarize --no-status $BUILD_PKGS_WHITELIST $CATKIN_PARALLEL_JOBS --make-args $ROS_PARALLEL_JOBS
        source install/setup.bash
    fi

    ici_time_end  # catkin_install_build
    ici_time_start catkin_install_run_tests

    export EXIT_STATUS=0
    # Test if the unit tests in the packages in the downstream repo pass.
    if [ "$BUILDER" == catkin ]; then
      for pkg in $PKGS_DOWNSTREAM; do
        echo "[$pkg] Started testing..."
        rostest_files=$(find install/share/$pkg -iname '*.test') || continue # metapackage do not install anything in share
        echo "[$pkg] Found $(echo $rostest_files | wc -w) tests."
        for test_file in $rostest_files; do
          echo "[$pkg] Testing $test_file"
          rostest $test_file || export EXIT_STATUS=$?
          if [ $? != 0 ]; then
            echo -e "[$pkg] Testing again the failed test: $test_file.\e[31m>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>\e[0m"
            rostest --text $test_file
            echo -e "[$pkg] Testing again the failed test: $test_file.\e[31m<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<\e[0m"
          fi
        done
      done
      [ $EXIT_STATUS -eq 0 ] || error  # unless all tests pass, raise error
    fi

    ici_time_end  # catkin_install_run_tests

fi

ici_time_start test_results

if [ "${ROS_DISTRO}" == "hydro" ]; then
    PATH=/usr/local/bin:$PATH  # for installed catkin_test_results
    PYTHONPATH=/usr/local/lib/python2.7/dist-packages:$PYTHONPATH

    if [ "${ROS_LOG_DIR// }" == "" ]; then export ROS_LOG_DIR=~/.ros/test_results; fi # http://wiki.ros.org/ROS/EnvironmentVariables#ROS_LOG_DIR
    if [ "$BUILDER" == catkin -a -e $ROS_LOG_DIR ]; then catkin_test_results --all $ROS_LOG_DIR || error; fi
    if [ "$BUILDER" == catkin -a -e $CATKIN_WORKSPACE/build/ ]; then catkin_test_results --all $CATKIN_WORKSPACE/build/ || error; fi
    if [ "$BUILDER" == catkin -a -e ~/.ros/test_results/ ]; then catkin_test_results --all ~/.ros/test_results/ || error; fi
else    
    catkin_test_results --verbose
fi

ici_time_end  # test_results