#!/bin/bash
set -e

# Repo config
gh_branch="main"
gh_user="hypha-bot"

# Gaiad versions to start upgrade
start_version="v6.0.4"

# Store current date and time
start_date=$(date +"%Y%m%d_%H-%M-%S")

# Stop cosmovisor
echo "Stopping cosmovisor"
systemctl stop cosmovisor

# Use quicksync as statesync is not reliable
echo "Installing utils needed to quicksync and git"
apt-get install wget liblz4-tool aria2 bc git-lfs -y

# Configure Git
echo "Configuring git"
cd ~
if [ ! -d ~/.ssh ]
then
    mkdir -m 700 ~/.ssh
fi
ssh-keyscan github.com >> ~/.ssh/known_hosts
git config --global credential.helper store
git config --global user.name "$gh_user"
git config --global user.email $gh_user@users.noreply.github.com
# Do not pull files in LFS by default
#git config --global filter.lfs.smudge "git-lfs smudge --skip -- %f"
#git config --global filter.lfs.process "git-lfs filter-process --skip"

# Gaiad Upgrade Test Function
gaiad_upgrade () {
    # do not exit on error
    set +e

    f_gaia_version=$1
    f_upgrade_version=$2
    f_latest_genesis=$3
    sed -e 's/testnet.com:/local:/g ; /genesis_url:/d' examples/inventory-local-genesis.yml > inventory.yml
    ansible-playbook gaia.yml -i inventory.yml --extra-vars "\
        reboot=false \
        minimum_gas_prices=0.0025uatom \
        gaiad_version=$f_gaia_version \
        gaiad_gov_testing=true \
        gaiad_user=gaia \
        priv_validator_key_file=examples/validator-keys/validator-40/priv_validator_key.json \
        node_key_file=examples/validator-keys/validator-40/node_key.json \
        genesis_file=$f_latest_genesis"
    
    # Test to see if gaia is building blocks
    tests/test_block_production.sh 127.0.0.1 26657 10
    if [ $? -ne 0 ]
    then
        echo "Failed to build blocks on version: $f_gaia_version"
        f_build_block=0
    else
        echo "Test building blocks for version: $f_gaia_version"
        f_build_block=1
    fi

    if [ $f_build_block -eq 1 ]
    then
        echo "Testing upgrade"
        tests/test_software_upgrade.sh 127.0.0.1 26657 $f_upgrade_version
        if [ $? -ne 0 ]
        then
            echo "Upgrade failed cannot build blocks on version: $f_upgrade_version"
        else
            echo "Upgrade Successful to version: $f_upgrade_version"
        fi
    else
        echo "Skipping upgrade test blocks are not being built!"
    fi
    # stop cosmovisor
    systemctl stop cosmovisor
    set -e
}

echo "Creating script for gaia user"
echo "#!/bin/bash
echo \"cd ~/.gaia\"
cd ~/.gaia
echo \"Set URL\"
URL=\$(curl https://quicksync.io/cosmos.json|jq -r '.[] |select(.file==\"cosmoshub-4-pruned\")|.url')
echo \"URL set to: \$URL\"
echo \"Starting download\"
aria2c -x5 \$URL
echo \"Download checksum script\"
wget https://raw.githubusercontent.com/chainlayer/quicksync-playbooks/master/roles/quicksync/files/checksum.sh
chmod +x checksum.sh
echo \"Download \$URL.checksum\"
wget \$URL.checksum
echo \"Get sha512sum\"
curl -s https://lcd-cosmos.cosmostation.io/txs/\$(curl -s \$URL.hash)|jq -r '.tx.value.memo'|sha512sum -c
echo \"Checking hash of download\"
./checksum.sh \$(basename \$URL) check
if [ \$? -ne 0 ]
then
	echo "Checksum FAILED falling back to statesync"
	rm \$(basename \$URL)
else
	echo \"Execting \$(basename \$URL)\"
	lz4 -d \$(basename \$URL) | tar xf -
	echo \"Removing \$(basename \$URL)\"
	rm \$(basename \$URL)
fi
if [ ! -d cosmovisor/upgrades ]
then
    echo \"Creating cosmovisor/upgrades/v7-Theta/bin directory\"
    mkdir -p cosmovisor/upgrades/v7-Theta/bin
    cp cosmovisor/genesis/bin/gaiad cosmovisor/upgrades/v7-Theta/bin/gaiad
fi
" > ~gaia/quicksync.sh
chmod +x ~gaia/quicksync.sh
# echo "Running ~gaia/quicksync.sh as gaia user"
# su gaia -c '~gaia/quicksync.sh'

# echo "Starting cosmovisor"
# systemctl start cosmovisor

# # Wait for gaia service to respond
# echo "Waiting for gaia to respond"
# attempt_counter=0
# max_attempts=100
# until $(curl --output /dev/null --silent --head --fail http://127.0.0.1:26657)
# do
#     if [ ${attempt_counter} -gt ${max_attempts} ]
#     then
#         echo ""
#         echo "Tried connecting to gaiad for $attempt_counter times. Exiting."
#         exit 1
#     fi

#     printf '.'
#     attempt_counter=$(($attempt_counter+1))
#     sleep 1
# done

# # Wait until gaiad is done catching up
# catching_up="true"
# while [ $catching_up == "true" ]
# do
# 	catching_up=$(curl -s 127.0.0.1:26657/status | jq -r .result.sync_info.catching_up)
# 	echo "catching up"
# 	sleep 5
# done
# echo "Done catching up"

# # Get current block height
# current_block=$(curl -s 127.0.0.1:26657/block | jq -r .result.block.header.height)
# echo "Current block: $current_block"

# # Get block timestamp
# current_block_time=$(curl -s 127.0.0.1:26657/block\?height=$current_block | jq -r .result.block.header.time)
# echo "Current block timestamp: $current_block_time"

# # Stop cosmovisor before exporting
# echo "stop cosmovisor"
# systemctl stop cosmovisor

# Clone cosmos-genesis-tinkerer
echo "Cloning cosmos-genesis-tinkerer"
cd ~
git clone git@github.com:hyphacoop/cosmos-genesis-tinkerer.git
cd cosmos-genesis-tinkerer/
git checkout $gh_branch

# # Get version number using gaiad version
# echo "Get running gaiad version"
# gaiad_version=$((su gaia -c "~gaia/.gaia/cosmovisor/current/bin/gaiad version") 2>&1)
# echo "Installed gaiad version is $gaiad_version"

# # Export genesis
# if [ ! -d mainnet-genesis-export ]
# then
#     mkdir mainnet-genesis-export
# fi
# echo "Export genesis"
# su gaia -c "~gaia/.gaia/cosmovisor/current/bin/gaiad export --height $current_block" 2> "mainnet-genesis-export/mainnet-genesis_${current_block_time}_${gaiad_version}_${current_block}.json"

# echo "Tinkering exported genesis"
# pip3 install -r requirements.txt
# ln -s "$PWD/mainnet-genesis-export/mainnet-genesis_${current_block_time}_${gaiad_version}_${current_block}.json" "tests/mainnet_genesis.json"
# python3 ./example_mainnet_genesis.py
# rm tests/mainnet_genesis.json
# if [ ! -d mainnet-genesis-tinkered ]
# then
#     mkdir mainnet-genesis-tinkered
# fi
# mv tinkered_genesis.json "mainnet-genesis-tinkered/tinkered-genesis_${current_block_time}_${gaiad_version}_${current_block}.json"


# # Compress files
# echo "Compressing mainnet-genesis-export/mainnet-genesis_${current_block_time}_${gaiad_version}_${current_block}.json"
# gzip "mainnet-genesis-export/mainnet-genesis_${current_block_time}_${gaiad_version}_${current_block}.json"
# echo "Compressing mainnet-genesis-tinkered/tinkered-genesis_${current_block_time}_${gaiad_version}_${current_block}.json"
# gzip "mainnet-genesis-tinkered/tinkered-genesis_${current_block_time}_${gaiad_version}_${current_block}.json"

# # Push to github
# echo "push to github"
# git lfs install
# git lfs track "*.gz"
# git add -A
# git commit -m "Adding mainnet and tinkered genesis at height $current_block"
# git push origin $gh_branch

# Print current date and time
echo -n "Finished at: "
date

# Test upgrade using exported genesis
echo "Test upgrades using export genesis"
cd ~
pip3 install ansible
git clone git@github.com:hyphacoop/cosmos-ansible.git
cd cosmos-ansible/
echo "transport = local" >> ansible.cfg
python3 tests/generate_version_matrix.py $start_version
upgrade=$(python3 tests/generate_upgrade_matrix.py $start_version)

# Loop through upgrade versions
i=0
jq -r .include[].gaia_version <<< $upgrade | while read -r gaia_start_version
do
    gaia_upgrade_version=$(jq -r ".include[$i].upgrade_version" <<< $upgrade)
    echo "Run test on $gaia_start_version to $gaia_upgrade_version"
    #gaiad_upgrade $gaia_start_version $gaia_upgrade_version ~/mainnet-genesis-export/mainnet-genesis_${current_block_time}_${gaiad_version}_${current_block}.json
    # static file for testing
    gaiad_upgrade $gaia_start_version $gaia_upgrade_version tinkered-genesis_2022-06-18T22:07:07.89761993Z_v7.0.2_10933559.json.gz
    let i=$i+1
done

# # Push log to cosmos-configurations-private repo
# echo "Push log to cosmos-configurations-private repo"
# cd ~
# git clone git@github.com:hyphacoop/cosmos-configurations-private.git
# cd cosmos-configurations-private
# if [ ! -d logs/mainnet-export ]
# then
#     mkdir -p logs/mainnet-export
# fi
# # wait for log to be written
# sleep 120
# cp /root/export_genesis.log "logs/mainnet-export/mainnet-genesis_${start_date}_${gaiad_version}_${current_block}.log"
# git add -A
# git commit -m "Adding export log file"
# git push origin main

# DESTROY the droplet from itself
#curl -X DELETE -H "Authorization: Bearer {{ digitalocean_api_key }}" "https://api.digitalocean.com/v2/droplets/{{ droplet_id }}"
