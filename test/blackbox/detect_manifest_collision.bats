# Note: Intended to be run as "make run-blackbox-tests" or "make run-blackbox-ci"
#       Makefile target installs & checks all necessary tooling
#       Extra tools that are not covered in Makefile target needs to be added in verify_prerequisites()

load helpers_zot

function verify_prerequisites {
    if [ ! $(command -v htpasswd) ]; then
        echo "you need to install htpasswd as a prerequisite to running the tests" >&3
        return 1
    fi

    return 0
}

function setup_file() {
    # Verify prerequisites are available
    if ! $(verify_prerequisites); then
        exit 1
    fi

    # Download test data to folder common for the entire suite, not just this file
    skopeo --insecure-policy copy --format=oci docker://ghcr.io/project-zot/test-images/busybox:1.36 oci:${TEST_DATA_DIR}/busybox:1.36

    # Setup zot server
    local zot_root_dir=${BATS_FILE_TMPDIR}/zot
    local zot_config_file=${BATS_FILE_TMPDIR}/zot_config.json
    local oci_data_dir=${BATS_FILE_TMPDIR}/oci
    local zot_htpasswd_file=${BATS_FILE_TMPDIR}/htpasswd
    mkdir -p ${zot_root_dir}
    mkdir -p ${oci_data_dir}
    zot_port=$(get_free_port)
    echo ${zot_port} > ${BATS_FILE_TMPDIR}/zot.port
    htpasswd -Bbn ${AUTH_USER} ${AUTH_PASS} >> ${zot_htpasswd_file}
    cat > ${zot_config_file}<<EOF
{
    "distSpecVersion": "1.1.0",
    "storage": {
        "rootDirectory": "${zot_root_dir}"
    },
    "http": {
        "address": "127.0.0.1",
        "port": "${zot_port}",
        "auth": {
            "htpasswd": {
                "path": "${zot_htpasswd_file}"
            }
        },
        "accessControl": {
            "repositories": {
                "**": {
                    "anonymousPolicy": [
                        "read",
                        "create",
                        "delete",
                        "detectManifestCollision"
                    ],
                    "policies": [
                        {
                            "users": [
                                "${AUTH_USER}"
                            ],
                            "actions": [
                                "read",
                                "create",
                                "delete"
                            ]
                        }
                    ]
                }
            }
        }
    },
    "log": {
        "level": "debug",
        "output": "${BATS_FILE_TMPDIR}/zot.log"
    }
}
EOF
    zot_serve ${ZOT_PATH} ${zot_config_file}
    wait_zot_reachable ${zot_port}
}

function teardown() {
    # conditionally printing on failure is possible from teardown but not from from teardown_file
    cat ${BATS_FILE_TMPDIR}/zot.log
}

function teardown_file() {
    zot_stop_all
}

@test "push 2 images with same manifest with user policy" {
    zot_port=`cat ${BATS_FILE_TMPDIR}/zot.port`
    run skopeo --insecure-policy copy --dest-creds ${AUTH_USER}:${AUTH_PASS} --dest-tls-verify=false \
        oci:${TEST_DATA_DIR}/busybox:1.36 \
        docker://127.0.0.1:${zot_port}/busybox:1.36
    [ "$status" -eq 0 ]

    run skopeo --insecure-policy copy --dest-creds ${AUTH_USER}:${AUTH_PASS} --dest-tls-verify=false \
        oci:${TEST_DATA_DIR}/busybox:1.36 \
        docker://127.0.0.1:${zot_port}/busybox:latest
    [ "$status" -eq 0 ]
}

@test "skopeo delete image with anonymous policy should fail" {
    zot_port=`cat ${BATS_FILE_TMPDIR}/zot.port`
    # skopeo deletes by digest, so it should fail with detectManifestCollision policy
    run skopeo --insecure-policy delete --tls-verify=false \
        docker://127.0.0.1:${zot_port}/busybox:1.36
    [ "$status" -eq 1 ]
    # conflict status code
    [[ "$output" == *"manifest invalid"* ]]
}

@test "regctl delete image with anonymous policy should fail" {
    zot_port=`cat ${BATS_FILE_TMPDIR}/zot.port`
    run regctl registry set localhost:${zot_port} --tls disabled
    [ "$status" -eq 0 ]

    run regctl image delete localhost:${zot_port}/busybox:1.36 --force-tag-dereference
    [ "$status" -eq 1 ]
    # conflict status code
    [[ "$output" == *"409"* ]]
}

@test "delete image with user policy should work" {
    zot_port=`cat ${BATS_FILE_TMPDIR}/zot.port`
    # should work without detectManifestCollision policy
    run skopeo --insecure-policy delete --creds ${AUTH_USER}:${AUTH_PASS} --tls-verify=false \
        docker://127.0.0.1:${zot_port}/busybox:1.36
    [ "$status" -eq 0 ]
}
