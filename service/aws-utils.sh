#!/usr/bin/env bash

: "${IMDS_BASE_URL:=http://169.254.169.254/latest}"
IMDS_TIMEOUT=5

# usage: imds <token> <path>
function imds {
  curl -sf \
        --connect-timeout $IMDS_TIMEOUT \
        -H "X-aws-ec2-metadata-token: $1" \
        "${IMDS_BASE_URL}/meta-data/$2"
}

# usage: get_imds_token
function get_imds_token {
  curl -sf -X PUT \
    --connect-timeout $IMDS_TIMEOUT \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" \
    "$IMDS_BASE_URL/api/token"
}

function get_region {
    imds "$1" "placement/region" 2>/dev/null
}

function get_instance_id {
    imds "$1" "instance-id" 2>/dev/null
}

# usage: get_target_lifecycle_state <token>
function get_target_lifecycle_state {
  imds "$1" "autoscaling/target-lifecycle-state" 2>/dev/null
}

# fetch iam credentials from imds and make a sigv4-signed post request
# to the aws query api. returns raw xml response body
# usage: aws_sigv4_request <token> <service> <region> <payload>
function aws_sigv4_request {
    local token="$1"
    local service="$2"
    local region="$3"
    local payload="$4"

    local role=$(imds "$token" "iam/security-credentials/")
    local creds=$(imds "$token" "iam/security-credentials/${role}")

    local access_key=$(echo "${creds}" | grep -o '"AccessKeyId" : "[^"]*"' | cut -d'"' -f4)
    local secret_key=$(echo "${creds}" | grep -o '"SecretAccessKey" : "[^"]*"' | cut -d'"' -f4)
    local session_token=$(echo "${creds}" | grep -o '"Token" : "[^"]*"' | cut -d'"' -f4)

    local host="${service}.${region}.amazonaws.com"
    local content_type="application/x-www-form-urlencoded"
    local amz_date=$(date -u +"%Y%m%dT%H%M%SZ")
    local date_stamp=$(date -u +"%Y%m%d")

    local payload_hash=$(echo -n "${payload}" | openssl dgst -sha256 | awk '{print $2}')
    local canonical_headers="content-type:${content_type}\nhost:${host}\nx-amz-date:${amz_date}\nx-amz-security-token:${session_token}\n"
    local signed_headers="content-type;host;x-amz-date;x-amz-security-token"
    local canonical_request="POST\n/\n\n${canonical_headers}\n${signed_headers}\n${payload_hash}"

    local algorithm="AWS4-HMAC-SHA256"
    local credential_scope="${date_stamp}/${region}/${service}/aws4_request"
    local canonical_request_hash=$(echo -en "${canonical_request}" | openssl dgst -sha256 | awk '{print $2}')
    local string_to_sign="${algorithm}\n${amz_date}\n${credential_scope}\n${canonical_request_hash}"

    hmac_sha256_hex() {
        echo -n "$2" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$1" | awk '{print $2}'
    }

    local k_secret=$(printf "AWS4%s" "${secret_key}" | od -A n -t x1 | tr -d ' \n')
    local k_date=$(hmac_sha256_hex "${k_secret}" "${date_stamp}")
    local k_region=$(hmac_sha256_hex "${k_date}" "${region}")
    local k_service=$(hmac_sha256_hex "${k_region}" "${service}")
    local k_signing=$(hmac_sha256_hex "${k_service}" "aws4_request")
    local signature=$(echo -en "${string_to_sign}" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:${k_signing}" | awk '{print $2}')

    local auth_header="${algorithm} Credential=${access_key}/${credential_scope}, SignedHeaders=${signed_headers}, Signature=${signature}"

    curl -s -X POST "https://${host}/" \
        -H "Content-Type: ${content_type}" \
        -H "X-Amz-Date: ${amz_date}" \
        -H "X-Amz-Security-Token: ${session_token}" \
        -H "Authorization: ${auth_header}" \
        -d "${payload}"
}

# usage: get_asg_lifecycle_state <token> <instance_id>
function get_asg_lifecycle_state {
    local token="$1"
    local instance_id="$2"
    local region=$(get_region "${token}")
    local payload="Action=DescribeAutoScalingInstances&InstanceIds.member.1=${instance_id}&Version=2011-01-01"
    aws_sigv4_request "${token}" "autoscaling" "${region}" "${payload}" \
        | grep -o '<LifecycleState>[^<]*</LifecycleState>' | sed 's/<[^>]*>//g'
}

# usage: get_asg_healthy_instance_id <token> <region> <asg_name>
function get_asg_healthy_instance_id {
    local token="$1"
    local region="$2"
    local asg_name="$3"
    local payload="Action=DescribeAutoScalingGroups&AutoScalingGroupNames.member.1=${asg_name}&Version=2011-01-01"
    aws_sigv4_request "${token}" "autoscaling" "${region}" "${payload}" \
        | grep -o '<member>.*</member>' \
        | grep '<LifecycleState>InService</LifecycleState>' \
        | grep '<HealthStatus>Healthy</HealthStatus>' \
        | grep -o '<InstanceId>[^<]*</InstanceId>' \
        | sed 's/<[^>]*>//g' \
        | head -1
}

# usage: complete_lifecycle_action <token> <region> <asg_name> <hook_name> <instance_id> <action>
function complete_lifecycle_action {
    local token="$1"
    local region="$2"
    local asg_name="$3"
    local hook_name="$4"
    local instance_id="$5"
    local action="$6"
    local payload="Action=CompleteLifecycleAction&AutoScalingGroupName=${asg_name}&LifecycleHookName=${hook_name}&InstanceId=${instance_id}&LifecycleActionResult=${action}&Version=2011-01-01"
    aws_sigv4_request "${token}" "autoscaling" "${region}" "${payload}" > /dev/null
}

# usage: get_network_attachment_id <token> <region> <eni_id>
function get_network_attachment_id {
    local token="$1"
    local region="$2"
    local eni_id="$3"
    local payload="Action=DescribeNetworkInterfaceAttribute&NetworkInterfaceId=${eni_id}&Attribute=attachment&Version=2016-11-15"
    aws_sigv4_request "${token}" "ec2" "${region}" "${payload}" \
        | grep -o '<attachmentId>[^<]*</attachmentId>' | sed 's/<[^>]*>//g'
}

# usage: detach_network_interface <token> <region> <eni_id>
function detach_network_interface {
    local token="$1"
    local region="$2"
    local eni_id="$3"
    local attachment_id=$(get_network_attachment_id "${token}" "${region}" "${eni_id}")
    if [ -n "$attachment_id" ]; then
        local payload="Action=DetachNetworkInterface&AttachmentId=${attachment_id}&Force=true&Version=2016-11-15"
        aws_sigv4_request "${token}" "ec2" "${region}" "${payload}" > /dev/null
        # wait until network interface is completely detached
        while [ -n "$attachment_id" ]; do
            attachment_id=$(get_network_attachment_id "${token}" "${region}" "${eni_id}")
            sleep 2
        done
    fi
}

# usage: associate_eip <token> <region> <allocation_id> <eni_id>
function associate_eip {
    local token="$1"
    local region="$2"
    local allocation_id="$3"
    local eni_id="$4"
    local payload="Action=AssociateAddress&AllocationId=${allocation_id}&NetworkInterfaceId=${eni_id}&AllowReassociation=true&Version=2016-11-15"
    aws_sigv4_request "${token}" "ec2" "${region}" "${payload}" > /dev/null
}

# usage: attach_network_interface <token> <region> <instance_id> <eni_id>
function attach_network_interface {
    local token="$1"
    local region="$2"
    local instance_id="$3"
    local eni_id="$4"
    local payload="Action=AttachNetworkInterface&InstanceId=${instance_id}&DeviceIndex=1&NetworkInterfaceId=${eni_id}&Version=2016-11-15"
    local response=$(aws_sigv4_request "${token}" "ec2" "${region}" "${payload}")
    echo "${response}" | grep -q '<attachmentId>' && return 0 || return 1
}

# usage: disable_source_dest_check <token> <region> <eni_id>
function disable_source_dest_check {
    local token="$1"
    local region="$2"
    local eni_id="$3"
    local payload="Action=ModifyNetworkInterfaceAttribute&NetworkInterfaceId=${eni_id}&SourceDestCheck.Value=false&Version=2016-11-15"
    aws_sigv4_request "${token}" "ec2" "${region}" "${payload}" > /dev/null
}

function instance_has_network_interface_attached {
    has=$(aws ec2 describe-network-interface-attribute \
        --region "$1" \
        --network-interface-id $3 \
        --attribute attachment \
        --query "Attachment.InstanceId == '$2'")
    [ "$has" == "true" ] && return 0 || return 1
}