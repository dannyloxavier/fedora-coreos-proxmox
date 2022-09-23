#!/bin/bash

#set -e

vmid="$1"
phase="$2"

# global vars
COREOS_TMPLT=/opt/fcos-tmplt.yaml
COREOS_FILES_PATH=/etc/pve/geco-pve/coreos
#YQ="yq read --exitStatus --printMode v --stripComments --" #DEPRECATED
YQ="/usr/local/bin/yq -e -r"

# ==================================================================================================================================================================
# functions()
#
setup_fcoreosct()
{
        local CT_VER=0.15.0
        local ARCH=x86_64
        local OS=unknown-linux-gnu # Linux
        local DOWNLOAD_URL=https://github.com/coreos/butane/releases/download

        [[ -x /usr/local/bin/butane ]]&& [[ "x$(/usr/local/bin/butane --version | awk '{print $NF}')" == "x${CT_VER}" ]]&& return 0
        echo "Setup Fedora CoreOS config transpiler..."
        rm -f /usr/local/bin/fcos-ct
        wget --quiet --show-progress ${DOWNLOAD_URL}/v${CT_VER}/butane-${ARCH}-${OS} -O /usr/local/bin/butane
	ln -s /usr/local/bin/butane /usr/local/bin/fcos-ct
        chmod 755 /usr/local/bin/fcos-ct
}
setup_fcoreosct

setup_yq()
{
        local VER=4.27.5

        [[ -x /usr/bin/wget ]]&& download_command="wget --quiet --show-progress --output-document"  || download_command="curl --location --output"
        [[ -x /usr/local/bin/yq ]]&& [[ "x$(/usr/local/bin/yq --version | awk '{print $NF}')" == "x${VER}" ]]&& return 0
        echo "Setup yaml parser tools yq..."
        rm -f /usr/local/bin/yq
		${download_command} /usr/local/bin/yq https://github.com/mikefarah/yq/releases/download/v${VER}/yq_linux_amd64
        chmod 755 /usr/local/bin/yq
}
setup_yq

# ==================================================================================================================================================================
# main()
#
if [[ "${phase}" == "pre-start" ]]
then
	instance_id="$(qm cloudinit dump ${vmid} meta | ${YQ} '.instance-id')"

	# same cloudinit config ?
	[[ -e ${COREOS_FILES_PATH}/${vmid}.id ]] && [[ "x${instance_id}" != "x$(cat ${COREOS_FILES_PATH}/${vmid}.id)" ]]&& {
		rm -f ${COREOS_FILES_PATH}/${vmid}.ign # cloudinit config change
	}
	[[ -e ${COREOS_FILES_PATH}/${vmid}.ign ]]&& exit 0 # already done

	mkdir -p ${COREOS_FILES_PATH} || exit 1

	# check config
	cipasswd="$(qm cloudinit dump ${vmid} user | ${YQ} '.password' 2> /dev/null)" || true # can be empty
	[[ "x${cipasswd}" != "x" ]]&& VALIDCONFIG=true
	ssh_authorized_keys="$(qm cloudinit dump ${vmid} user | ${YQ} '.ssh_authorized_keys | select (. != null)' 2> /dev/null)"
	${VALIDCONFIG:-false} || [[ "x${ssh_authorized_keys}" == "x" ]]|| VALIDCONFIG=true
	${VALIDCONFIG:-false} || {
		echo "Fedora CoreOS: you must set passwd or ssh-key before start VM${vmid}"
		exit 1
	}

	echo -n "Fedora CoreOS: Generate yaml users block... "
	echo -e "# This file is managed by Geco-iT hook-script. Do not edit.\n" > ${COREOS_FILES_PATH}/${vmid}.yaml
	echo -e "variant: fcos\nversion: 1.4.0" >> ${COREOS_FILES_PATH}/${vmid}.yaml
	echo -e "# user\npasswd:\n  users:" >> ${COREOS_FILES_PATH}/${vmid}.yaml
	ciuser="$(qm cloudinit dump ${vmid} user 2> /dev/null | grep ^user: | awk '{print $NF}')"
	echo "    - name: \"${ciuser:-admin}\"" >> ${COREOS_FILES_PATH}/${vmid}.yaml
	echo "      gecos: \"Geco-iT CoreOS Administrator\"" >> ${COREOS_FILES_PATH}/${vmid}.yaml
	echo "      password_hash: '${cipasswd}'" >> ${COREOS_FILES_PATH}/${vmid}.yaml
	echo '      groups: [ "sudo", "docker", "adm", "wheel", "systemd-journal" ]' >> ${COREOS_FILES_PATH}/${vmid}.yaml
	if [[ "${ssh_authorized_keys}" != '' ]]
	then
		echo '      ssh_authorized_keys:' >> ${COREOS_FILES_PATH}/${vmid}.yaml
		printf '%b\n' "$ssh_authorized_keys" | sed -e 's/^-/        -/' >> ${COREOS_FILES_PATH}/${vmid}.yaml 2> /dev/null
	fi
	echo >> ${COREOS_FILES_PATH}/${vmid}.yaml
	echo "[done]"

	echo -n "Fedora CoreOS: Generate yaml hostname block... "
	hostname="$(qm cloudinit dump ${vmid} user | ${YQ} '.hostname' 2> /dev/null)"
	echo -e "# network\nstorage:\n  files:" >> ${COREOS_FILES_PATH}/${vmid}.yaml
	echo "    - path: /etc/hostname" >> ${COREOS_FILES_PATH}/${vmid}.yaml
	echo "      mode: 0644" >> ${COREOS_FILES_PATH}/${vmid}.yaml
	echo "      overwrite: true" >> ${COREOS_FILES_PATH}/${vmid}.yaml
	echo "      contents:" >> ${COREOS_FILES_PATH}/${vmid}.yaml
	echo "        inline: |" >> ${COREOS_FILES_PATH}/${vmid}.yaml
	echo -e "          ${hostname,,}\n" >> ${COREOS_FILES_PATH}/${vmid}.yaml
	echo "[done]"

	echo -n "Fedora CoreOS: Generate yaml network block... "
	network="$(qm cloudinit dump ${vmid} network)"
	netcards="$(printf '%b\n' "$network" | ${YQ} '.config[].name | select (. != null)' 2> /dev/null | wc -l)"
	nameservers="$(printf '%b\n' "$network" | ${YQ} ".config[${netcards}].address" | sed -Ee "s@(- |')@@g" | paste -s -d ";" -)"
	searchdomain="$(printf '%b\n' "$network" | ${YQ} ".config[${netcards}].search" | sed -Ee "s@(- |')@@g" | paste -s -d ";" -)"

	# Network functions
	function vars_ipv4 {
		# start IPv4
		ipv4="$(printf '%b\n' "$1" | ${YQ} ".config[${2}].subnets[0].address" 2> /dev/null)"
		netmask="$(printf '%b\n' "$1" | ${YQ} ".config[${2}].subnets[0].netmask" 2> /dev/null)"
		gw="$(printf '%b\n' "$1" | ${YQ} ".config[${2}].subnets[0].gateway" 2> /dev/null)" || true # can be empty
		macaddr="$(printf '%b\n' "$1" | ${YQ} ".config[${2}].mac_address" 2> /dev/null)"
	}

	function vars_ipv6 {
		# start IPv6
		ipv6="$(printf '%b\n' "$1" | ${YQ} ".config[${2}].subnets[1].address" 2> /dev/null)"
		gw6="$(printf '%b\n' "$1" | ${YQ} ".config[${2}].subnets[1].gateway" 2> /dev/null)" || true # can be empty
		macaddr6="$(printf '%b\n' "$1" | ${YQ} ".config[${2}].mac_address" 2> /dev/null)"
	}

	# Write vars to files functions
	function write_header {
		echo "    - path: /etc/NetworkManager/system-connections/net${1}.nmconnection" >> ${COREOS_FILES_PATH}/${vmid}.yaml
		echo "      mode: 0600" >> ${COREOS_FILES_PATH}/${vmid}.yaml
		echo "      overwrite: true" >> ${COREOS_FILES_PATH}/${vmid}.yaml
		echo "      contents:" >> ${COREOS_FILES_PATH}/${vmid}.yaml
		echo "        inline: |" >> ${COREOS_FILES_PATH}/${vmid}.yaml
		echo "          [connection]" >> ${COREOS_FILES_PATH}/${vmid}.yaml
		echo "          type=ethernet" >> ${COREOS_FILES_PATH}/${vmid}.yaml
		echo "          id=net${i}" >> ${COREOS_FILES_PATH}/${vmid}.yaml
		echo "          #interface-name=eth${i}\n" >> ${COREOS_FILES_PATH}/${vmid}.yaml
		echo -e "\n          [ethernet]" >> ${COREOS_FILES_PATH}/${vmid}.yaml
		echo -e "          mac-address=${macaddr}\n" >> ${COREOS_FILES_PATH}/${vmid}.yaml
	}

	function write_ipv4 {
		echo "          [ipv4]" >> ${COREOS_FILES_PATH}/${vmid}.yaml
		echo "          method=manual" >> ${COREOS_FILES_PATH}/${vmid}.yaml
		echo "          addresses=${ipv4}/${netmask}" >> ${COREOS_FILES_PATH}/${vmid}.yaml
		echo "          gateway=${gw}" >> ${COREOS_FILES_PATH}/${vmid}.yaml
	}

	function write_ipv6 {
		echo "          [ipv6]" >> ${COREOS_FILES_PATH}/${vmid}.yaml
		echo "          method=manual" >> ${COREOS_FILES_PATH}/${vmid}.yaml
		echo "          addresses=${ipv6}" >> ${COREOS_FILES_PATH}/${vmid}.yaml
		echo "          gateway=${gw6}" >> ${COREOS_FILES_PATH}/${vmid}.yaml
	}

	function write_nameservers {
		echo "          dns=${nameservers}" >> ${COREOS_FILES_PATH}/${vmid}.yaml
		echo -e "          dns-search=${searchdomain}\n" >> ${COREOS_FILES_PATH}/${vmid}.yaml
	}

	for (( i=O; i<${netcards}; i++ ))
	do
		net_type="$(printf '%b\n' "$network" | ${YQ} ".config[${i}].subnets[0].type")"
		net_type6="$(printf '%b\n' "$network" | ${YQ} ".config[${i}].subnets[1].type | select (. != null)" 2> /dev/null)"
		ipv4="" netmask="" gw="" macaddr="" ipv6="" gw6="" macaddr6="" # reset on each run
		# TODO: using DHCP
		case "$net_type $net_type6" in
			"static static6")
				vars_ipv4 "$network" "${i}"
				vars_ipv6 "$network" "${i}"
				write_header "${i}"
				write_ipv4
				write_nameservers
				write_ipv6
				echo "" >> ${COREOS_FILES_PATH}/${vmid}.yaml
				;;
			"static ")
				vars_ipv4 "$network" "${i}"
				write_header "${i}"
				write_ipv4
				write_nameservers
				;;
			"static6 ")
				vars_ipv6 "$network" "${i}"
				write_header "${i}"
				write_ipv6
				write_nameservers
				;;
		esac

	done
	echo "[done]"

	[[ -e "${COREOS_TMPLT}" ]]&& {
		echo -n "Fedora CoreOS: Generate other block based on template... "
		cat "${COREOS_TMPLT}" >> ${COREOS_FILES_PATH}/${vmid}.yaml
		echo "[done]"
	}

	echo -n "Fedora CoreOS: Generate ignition config... "
	/usr/local/bin/fcos-ct 	--pretty --strict \
				--output ${COREOS_FILES_PATH}/${vmid}.ign \
				${COREOS_FILES_PATH}/${vmid}.yaml 2> /dev/null
	[[ $? -eq 0 ]] || {
		echo "[failed]"
		exit 1
	}
	echo "[done]"

	# save cloudinit instanceid
	echo "${instance_id}" > ${COREOS_FILES_PATH}/${vmid}.id

	# check vm config (no args on first boot)
	qm config ${vmid} --current | grep -q ^args || {
		echo -n "Set args com.coreos/config on VM${vmid}... "
		rm -f /var/lock/qemu-server/lock-${vmid}.conf
		pvesh set /nodes/$(hostname)/qemu/${vmid}/config --args "-fw_cfg name=opt/com.coreos/config,file=${COREOS_FILES_PATH}/${vmid}.ign" 2> /dev/null || {
			echo "[failed]"
			exit 1
		}
		touch /var/lock/qemu-server/lock-${vmid}.conf

		# hack for reload new ignition file
		echo -e "\nWARNING: New generated Fedora CoreOS ignition settings, we must restart vm..."
		qm stop ${vmid} && sleep 2 && qm start ${vmid}&
		exit 1
	}
fi

exit 0
