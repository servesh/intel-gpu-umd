#!/usr/bin/env bash
if [ -f /etc/bashrc ]; then
	. /etc/bashrc
fi

set +o xtrace
set -o errexit

HOST=$(hostname -f)
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
NPROC=$(NP=$(nproc); echo "( $NP / 2 ) - 8" | bc)
DATE=$(date '+%Y.%m.%d')
: ${BUILD_DATE:=$DATE}

MODULES=("spack" "gcc" "cmake" "ninja")
BUILDTYP="Release"
: ${CODE_DEPLOY_DIR:="/tmp/intel-gpu-umd-install"}
: ${MODULE_DEPLOY_DIR:="/tmp/modulefiles/intel_compute_runtime/release"}

load_build_env()
{
	ml purge
	for i in ${!MODULE_LOCATIONS[@]}; do
		if [[ -d "${MODULE_LOCATIONS[i]}" ]]; then
			ml use ${MODULE_LOCATIONS[i]};
		else
			echo "Warning: Module location ${MODULE_LOCATIONS[i]} is not found in $HOST"
		fi
	done

	for i in ${!MODULES[@]}; do
		if [[ -n "$(ml av ${MODULES[i]} | grep ${MODULES[i]} &> /dev/null; echo $?)" ]]; then
			ml ${MODULES[i]};
		else
			echo "Warning: Module ${MODULES[i]} is not found in $HOST"
		fi
	done

	ml -t
}

COMPILER_BUILD_DIR=$(mktemp -d -t compiler.build.$DATE.XXXXXXXXXX)
DRIVER_BUILD_DIR=$(mktemp -d -t driver.build.$DATE.XXXXXXXXXX)
SOURCES_DIR=$(pwd)
DEPLOY_COMMIT=$( cd $SOURCES_DIR; git describe --exact-match --tags 2> /dev/null || git rev-parse --short HEAD )
DEPLOY_SUBJECT=$( cd $SOURCES_DIR; git log -1 --pretty="format:%<(61,trunc)%s" )
DEPLOY_SOURCE=$( cd $SOURCES_DIR; git remote -v |& grep fetch | awk -F " |@|:" '{print $2}' )
DEPLOY_REPO=$( cd $SOURCES_DIR; git remote -v |& grep fetch | awk -F " |@|:" '{print $3}' )
DEPLOY_USER=$( cd $SOURCES_DIR; git show -s --format='%cn' )
DEPLOY_EMAIL=$( cd $SOURCES_DIR; git show -s --format='%ce' )
CODE_DEPLOY_DIR=$CODE_DEPLOY_DIR/$DEPLOY_COMMIT-$BUILD_DATE

build_compiler()
{
	#Need to clone with entire repo's history, since the IGC build uses git history for patching
	#Stage directories are ignored for build sources
	cd $SOURCES_DIR/compiler
	rm -rf llvm-project &> /dev/null
	git clone -l llvm-project-stage llvm-project
	git clone -l SPIRV-LLVM-Translator-stage llvm-project/llvm/projects/llvm-spirv
	git clone -l opencl-clang-stage llvm-project/llvm/projects/opencl-clang

	rm -rf $COMPILER_BUILD_DIR
	set -o xtrace
	cmake -DCMAKE_BUILD_TYPE=$BUILDTYP -DCMAKE_INSTALL_PREFIX=$CODE_DEPLOY_DIR/compiler -DIGC_OPTION__LLVM_PREFERRED_VERSION=11.1.0 -S ./igc/IGC -B $COMPILER_BUILD_DIR -G Ninja -Wno-dev
	cmake --build $COMPILER_BUILD_DIR --parallel $NPROC
	cmake --install $COMPILER_BUILD_DIR
	set +o xtrace
	cd ..
	rm -rf $COMPILER_BUILD_DIR
}

build_runtime()
{
	cd $SOURCES_DIR/driver
	export INCLUDE=$CODE_DEPLOY_DIR/driver/include:$INCLUDE
	export CMAKE_PREFIX_PATH=$CODE_DEPLOY_DIR/driver/share/cmake:$CODE_DEPLOY_DIR/driver/share:$CODE_DEPLOY_DIR/driver/lib/cmake:$CODE_DEPLOY_DIR/driver/lib:$CODE_DEPLOY_DIR/driver/lib64/cmake:$CODE_DEPLOY_DIR/driver/lib64:$CMAKE_PREFIX_PATH
	export LD_LIBRARY_PATH=$CODE_DEPLOY_DIR/driver/lib64:$LD_LIBRARY_PATH
	export PKG_CONFIG_PATH=$CODE_DEPLOY_DIR/driver/lib64/pkgconfig:$PKG_CONFIG_PATH
	git apply -v $SOURCES_DIR/patches/driver/*
	set -o xtrace
	RUNTIME_DEPS=("gmmlib" "metrics-discovery" "metrics-library" "level-zero-loader" "metee" "igsc")
	for COMPONENT_DIR in ${RUNTIME_DEPS[@]}; do
		rm -rf $DRIVER_BUILD_DIR
	 set -o xtrace
		cmake -DCMAKE_BUILD_TYPE=$BUILDTYP -DCMAKE_INSTALL_PREFIX=$CODE_DEPLOY_DIR/driver -S ./$COMPONENT_DIR -B $DRIVER_BUILD_DIR -G Ninja -Wno-dev
		cmake --build $DRIVER_BUILD_DIR --parallel $NPROC
		cmake --install $DRIVER_BUILD_DIR
	 set +o xtrace
	done

	rm -rf $DRIVER_BUILD_DIR
	cmake -DCMAKE_BUILD_TYPE=$BUILDTYP -DCMAKE_INSTALL_PREFIX=$CODE_DEPLOY_DIR/driver -DIGC_DIR=$CODE_DEPLOY_DIR/compiler -DLEVEL_ZERO_ROOT=$CODE_DEPLOY_DIR/driver -DLevelZero_INCLUDE_DIR=$CODE_DEPLOY_DIR/driver/include -DMETRICS_DISCOVERY_DIR=$CODE_DEPLOY_DIR/driver -DMETRICS_LIBRARY_DIR=$CODE_DEPLOY_DIR/driver -DGMM_DIR=$CODE_DEPLOY_DIR/driver -DIGSC_DIR=$CODE_DEPLOY_DIR/driver -DOCL_ICD_VENDORDIR=$CODE_DEPLOY_DIR/OpenCL/vendor -DNEO_ENABLE_i915_PRELIM_DETECTION=ON -DSUPPORT_XE_HP_CORE=ON -DSUPPORT_XE_HP_SDV=ON -DSUPPORT_PVC=ON -DNEO_SKIP_UNIT_TESTS=OFF -S ./intel-compute-runtime -B $DRIVER_BUILD_DIR -G Ninja -Wno-dev
	cmake --build $DRIVER_BUILD_DIR --parallel $NPROC
	cmake --install $DRIVER_BUILD_DIR

	rsync -aP OpenCL-Headers/CL $CODE_DEPLOY_DIR/driver/include/
	rsync -aP OpenCL-CLHPP/include/CL/cl2.hpp OpenCL-CLHPP/include/CL/opencl.hpp $CODE_DEPLOY_DIR/driver/include/CL/
	rm -rf $DRIVER_BUILD_DIR
	cmake -DCMAKE_BUILD_TYPE=$BUILDTYP -DCMAKE_INSTALL_PREFIX=$CODE_DEPLOY_DIR/driver -DOPENCL_ICD_LOADER_HEADERS_DIR=$CODE_DEPLOY_DIR/driver/include -S ./OpenCL-ICD-Loader -B $DRIVER_BUILD_DIR -G Ninja -Wno-dev
	cmake --build $DRIVER_BUILD_DIR --parallel $NPROC
	cmake --install $DRIVER_BUILD_DIR
	set +o xtrace
	rm -rf $DRIVER_BUILD_DIR
}

generate_module_files()
{
	set +m
	shopt -s lastpipe
	declare -A MOD_OUT
	LN=1;			MOD_OUT[ $LN, 0 ]="#%Module";																																																					MOD_OUT[ $LN, 1 ]="";
	((LN++)); MOD_OUT[ $LN, 0 ]="#";																																																								MOD_OUT[ $LN, 1 ]="";
	((LN++)); MOD_OUT[ $LN, 0 ]="# Intel GPU User Mode Driver (UMD) Module";																																				MOD_OUT[ $LN, 1 ]="";
	((LN++)); MOD_OUT[ $LN, 0 ]="# Auto generated by, ";																																														MOD_OUT[ $LN, 1 ]="";
	((LN++)); MOD_OUT[ $LN, 0 ]="# Source: $DEPLOY_SOURCE ";																																												MOD_OUT[ $LN, 1 ]="";
	((LN++)); MOD_OUT[ $LN, 0 ]="#   Repo: $DEPLOY_REPO ";																																													MOD_OUT[ $LN, 1 ]="";
	((LN++)); MOD_OUT[ $LN, 0 ]="# Commit: $DEPLOY_COMMIT ";																																												MOD_OUT[ $LN, 1 ]="";
	((LN++)); MOD_OUT[ $LN, 0 ]="#   Info: $DEPLOY_SUBJECT ";																																												MOD_OUT[ $LN, 1 ]="";
	((LN++)); MOD_OUT[ $LN, 0 ]="#   User: $DEPLOY_USER ";																																													MOD_OUT[ $LN, 1 ]="";
	((LN++)); MOD_OUT[ $LN, 0 ]="#  Email: $DEPLOY_EMAIL ";																																													MOD_OUT[ $LN, 1 ]="";
	((LN++)); MOD_OUT[ $LN, 0 ]="#";																																																								MOD_OUT[ $LN, 1 ]="";
	((LN++)); MOD_OUT[ $LN, 0 ]="set RED_BOLD           \"\033\[1;31m"\";																																						MOD_OUT[ $LN, 1 ]="";
	((LN++)); MOD_OUT[ $LN, 0 ]="set GREEN_BOLD         \"\033\[1;32m"\";																																						MOD_OUT[ $LN, 1 ]="";
	((LN++)); MOD_OUT[ $LN, 0 ]="set YELLOW_BOLD        \"\033\[1;33m"\";																																						MOD_OUT[ $LN, 1 ]="";
	((LN++)); MOD_OUT[ $LN, 0 ]="set BLUE_BOLD          \"\033\[1;34m"\";																																						MOD_OUT[ $LN, 1 ]="";
	((LN++)); MOD_OUT[ $LN, 0 ]="set CYAN_BOLD          \"\033\[1;96m"\";																																						MOD_OUT[ $LN, 1 ]="";
	((LN++)); MOD_OUT[ $LN, 0 ]="set BRIGHT_BLUE_BOLD   \"\033\[1;94m"\";																																						MOD_OUT[ $LN, 1 ]="";
	((LN++)); MOD_OUT[ $LN, 0 ]="set COLOR_RESET        \"\033\[0m"\";																																							MOD_OUT[ $LN, 1 ]="";
	((LN++)); MOD_OUT[ $LN, 0 ]="";																																																									MOD_OUT[ $LN, 1 ]="";
	((LN++)); MOD_OUT[ $LN, 0 ]="proc ModulesHelp { } {";																																														MOD_OUT[ $LN, 1 ]="";
	((LN++)); MOD_OUT[ $LN, 0 ]="puts stderr \"\tThis module loads Intel GPU User Mode Driver (UMD) stack\"";																				MOD_OUT[ $LN, 1 ]="  ";
	((LN++)); MOD_OUT[ $LN, 0 ]="puts stderr \"\twhich is built from the following upstream repos\"";																								MOD_OUT[ $LN, 1 ]="  ";
	((LN++)); MOD_OUT[ $LN, 0 ]="puts stderr \"    \"";																																															MOD_OUT[ $LN, 1 ]="  ";
	((LN++)); MOD_OUT[ $LN, 0 ]="puts stderr \"\t-----------------------------------------------------------------------------------------\"";			MOD_OUT[ $LN, 1 ]="  ";
	((LN++)); MOD_OUT[ $LN, 0 ]="puts stderr \"\t| Intel User Mode Driver (UMD) Stack                                                    |\"";			MOD_OUT[ $LN, 1 ]="  ";
	((LN++)); MOD_OUT[ $LN, 0 ]="puts stderr \"\t-----------------------------------------------------------------------------------------\"";			MOD_OUT[ $LN, 1 ]="  ";

	((LN++)); N_LN=$( printf "| %21s | %-61s |\n" "Source" "$DEPLOY_SOURCE" )	MOD_OUT[ $LN, 0 ]="puts stderr \"\t$N_LN\"";													MOD_OUT[ $LN, 1 ]="  ";
	((LN++)); N_LN=$( printf "| %21s | %-61s |\n" "Repo" "$DEPLOY_REPO" )			MOD_OUT[ $LN, 0 ]="puts stderr \"\t$N_LN\"";													MOD_OUT[ $LN, 1 ]="  ";
	((LN++)); N_LN=$( printf "| %21s | %-61s |\n" "Commit" "$DEPLOY_COMMIT" )	MOD_OUT[ $LN, 0 ]="puts stderr \"\t$N_LN\"";													MOD_OUT[ $LN, 1 ]="  ";
	((LN++)); N_LN=$( printf "| %21s | %-61s |\n" "Info" "$DEPLOY_SUBJECT" )	MOD_OUT[ $LN, 0 ]="puts stderr \"\t$N_LN\"";													MOD_OUT[ $LN, 1 ]="  ";
	((LN++)); N_LN=$( printf "| %21s | %-61s |\n" "User" "$DEPLOY_USER" )			MOD_OUT[ $LN, 0 ]="puts stderr \"\t$N_LN\"";													MOD_OUT[ $LN, 1 ]="  ";
	((LN++)); N_LN=$( printf "| %21s | %-61s |\n" "Email" "$DEPLOY_EMAIL" )		MOD_OUT[ $LN, 0 ]="puts stderr \"\t$N_LN\"";													MOD_OUT[ $LN, 1 ]="  ";
	((LN++)); MOD_OUT[ $LN, 0 ]="puts stderr \"\t-----------------------------------------------------------------------------------------\"";			MOD_OUT[ $LN, 1 ]="  ";
	((LN++)); MOD_OUT[ $LN, 0 ]="puts stderr \"\t| Commit                | Repo                                                          |\"";			MOD_OUT[ $LN, 1 ]="  ";
	((LN++)); MOD_OUT[ $LN, 0 ]="puts stderr \"\t-----------------------------------------------------------------------------------------\"";			MOD_OUT[ $LN, 1 ]="  ";
	GIT_INFO=$( cd $SOURCES_DIR; git submodule foreach 'git describe --exact-match --tags 2> /dev/null || git rev-parse --short HEAD; \
		git remote -v |& grep fetch; echo' |& awk 'BEGIN { RS = ""; FS="\n" } { print $2 " - " $3 }' |& awk '{printf "| %21s | %61-s |\n", $1, $4}' )
	echo -e "$GIT_INFO" | while read N_LN; do	((LN++));	MOD_OUT[ $LN, 0 ]="puts stderr \"\t$N_LN\""; MOD_OUT[ $LN, 1 ]="  "; done
	((LN++)); MOD_OUT[ $LN, 0 ]="puts stderr \"\t-----------------------------------------------------------------------------------------\"";			MOD_OUT[ $LN, 1 ]="  ";
	((LN++)); MOD_OUT[ $LN, 0 ]="}";																																																								MOD_OUT[ $LN, 1 ]="";
	((LN++)); MOD_OUT[ $LN, 0 ]="";																																																									MOD_OUT[ $LN, 1 ]="";
	((LN++)); MOD_OUT[ $LN, 0 ]="if { [is-loaded intel_compute_runtime] } {";																																				MOD_OUT[ $LN, 1 ]="";
	((LN++)); MOD_OUT[ $LN, 0 ]="module unload intel_compute_runtime";																																							MOD_OUT[ $LN, 1 ]="  ";
	((LN++)); MOD_OUT[ $LN, 0 ]="if { [is-loaded intel_compute_runtime ] && [ module-info mode load ] } {";																					MOD_OUT[ $LN, 1 ]="  ";
	((LN++)); MOD_OUT[ $LN, 0 ]="conflict intel_compute_runtime";																																										MOD_OUT[ $LN, 1 ]="    ";
	((LN++)); MOD_OUT[ $LN, 0 ]="puts -nonewline stderr \"\${RED_BOLD}\"";																																					MOD_OUT[ $LN, 1 ]="    ";
	((LN++)); MOD_OUT[ $LN, 0 ]="puts stderr \"!!!Warning!!! Unable to cleanly unload existing intel_compute_runtime module due to dependencies\"";	MOD_OUT[ $LN, 1 ]="    ";
	((LN++)); MOD_OUT[ $LN, 0 ]="puts -nonewline stderr \"\${RED_BOLD}\"";																																					MOD_OUT[ $LN, 1 ]="    ";
	((LN++)); MOD_OUT[ $LN, 0 ]="puts stderr \"!!!Warning!!! Use 'module switch -f <oldmodule> <newmodule>' to switch base components"\";						MOD_OUT[ $LN, 1 ]="    ";
	((LN++)); MOD_OUT[ $LN, 0 ]="puts -nonewline stderr \"\${RED_BOLD}\"";																																					MOD_OUT[ $LN, 1 ]="    ";
	((LN++)); MOD_OUT[ $LN, 0 ]="puts stderr \"!!!Warning!!! if not do 'module purge' to reset your environment"\";																	MOD_OUT[ $LN, 1 ]="    ";
	((LN++)); MOD_OUT[ $LN, 0 ]="puts -nonewline stderr \"\${COLOR_RESET}\"";																																				MOD_OUT[ $LN, 1 ]="    ";
	((LN++)); MOD_OUT[ $LN, 0 ]="return -code error";																																																MOD_OUT[ $LN, 1 ]="    ";
	((LN++)); MOD_OUT[ $LN, 0 ]="}";																																																								MOD_OUT[ $LN, 1 ]="  ";
	((LN++)); MOD_OUT[ $LN, 0 ]="}";																																																								MOD_OUT[ $LN, 1 ]="";
	((LN++)); MOD_OUT[ $LN, 0 ]="";																																																									MOD_OUT[ $LN, 1 ]="";

	((LN++)); MOD_OUT[ $LN, 0 ]="module load spack";																																																MOD_OUT[ $LN, 1 ]="";
	((LN++)); MOD_OUT[ $LN, 0 ]="module load gcc/10.2.0";																																														MOD_OUT[ $LN, 1 ]="";

	((LN++)); MOD_OUT[ $LN, 0 ]="prepend-path {PATH} \"$CODE_DEPLOY_DIR/driver/bin\"";																															MOD_OUT[ $LN, 1 ]="";
	((LN++)); MOD_OUT[ $LN, 0 ]="prepend-path {PATH} \"$CODE_DEPLOY_DIR/compiler/bin\"";																														MOD_OUT[ $LN, 1 ]="";
	((LN++)); MOD_OUT[ $LN, 0 ]="prepend-path {INCLUDE} \"$CODE_DEPLOY_DIR/driver/include\"";																												MOD_OUT[ $LN, 1 ]="";
	((LN++)); MOD_OUT[ $LN, 0 ]="prepend-path {INCLUDE} \"$CODE_DEPLOY_DIR/driver/include/level_zero\"";																						MOD_OUT[ $LN, 1 ]="";
	((LN++)); MOD_OUT[ $LN, 0 ]="prepend-path {INCLUDE} \"$CODE_DEPLOY_DIR/compiler/include\"";																											MOD_OUT[ $LN, 1 ]="";
	((LN++)); MOD_OUT[ $LN, 0 ]="prepend-path {CPATH} \"$CODE_DEPLOY_DIR/driver/include\"";																													MOD_OUT[ $LN, 1 ]="";
	((LN++)); MOD_OUT[ $LN, 0 ]="prepend-path {CPATH} \"$CODE_DEPLOY_DIR/driver/include/level_zero\"";																							MOD_OUT[ $LN, 1 ]="";
	((LN++)); MOD_OUT[ $LN, 0 ]="prepend-path {CPATH} \"$CODE_DEPLOY_DIR/compiler/include\"";																												MOD_OUT[ $LN, 1 ]="";
	((LN++)); MOD_OUT[ $LN, 0 ]="prepend-path {LIBRARY_PATH} \"$CODE_DEPLOY_DIR/driver/lib64\"";																										MOD_OUT[ $LN, 1 ]="";
	((LN++)); MOD_OUT[ $LN, 0 ]="prepend-path {LIBRARY_PATH} \"$CODE_DEPLOY_DIR/driver/lib64/intel-opencl\"";																				MOD_OUT[ $LN, 1 ]="";
	((LN++)); MOD_OUT[ $LN, 0 ]="prepend-path {LIBRARY_PATH} \"$CODE_DEPLOY_DIR/compiler/lib64\"";																									MOD_OUT[ $LN, 1 ]="";
	((LN++)); MOD_OUT[ $LN, 0 ]="prepend-path {LD_LIBRARY_PATH} \"$CODE_DEPLOY_DIR/driver/lib64\"";																									MOD_OUT[ $LN, 1 ]="";
	((LN++)); MOD_OUT[ $LN, 0 ]="prepend-path {LD_LIBRARY_PATH} \"$CODE_DEPLOY_DIR/driver/lib64/intel-opencl\"";																		MOD_OUT[ $LN, 1 ]="";
	((LN++)); MOD_OUT[ $LN, 0 ]="prepend-path {LD_LIBRARY_PATH} \"$CODE_DEPLOY_DIR/compiler/lib64\"";																								MOD_OUT[ $LN, 1 ]="";
	((LN++)); MOD_OUT[ $LN, 0 ]="prepend-path {PKG_CONIG_PATH} \"$CODE_DEPLOY_DIR/driver/lib64/pkgconfig\"";																				MOD_OUT[ $LN, 1 ]="";
	((LN++)); MOD_OUT[ $LN, 0 ]="prepend-path {PKG_CONIG_PATH} \"$CODE_DEPLOY_DIR/compiler/lib64/pkgconfig\"";																			MOD_OUT[ $LN, 1 ]="";
	((LN++)); MOD_OUT[ $LN, 0 ]="prepend-path {CMAKE_PREFIX_PATH} \"$CODE_DEPLOY_DIR/driver/lib/cmake\"";																						MOD_OUT[ $LN, 1 ]="";
	((LN++)); MOD_OUT[ $LN, 0 ]="prepend-path {CMAKE_PREFIX_PATH} \"$CODE_DEPLOY_DIR/driver\"";																											MOD_OUT[ $LN, 1 ]="";
	((LN++)); MOD_OUT[ $LN, 0 ]="prepend-path {CMAKE_PREFIX_PATH} \"$CODE_DEPLOY_DIR/compiler\"";																										MOD_OUT[ $LN, 1 ]="";

	for(( i = 1; i <= $LN; i++ ))
	do
		printf "${MOD_OUT[ $i, 1 ]}%s\n" "${MOD_OUT[ $i, 0 ]}" &>> $MODULE_DEPLOY_DIR/$BUILD_DATE-$DEPLOY_COMMIT
	done
	set -m
	shopt -u lastpipe
}

load_build_env
build_compiler
build_runtime
generate_module_files
