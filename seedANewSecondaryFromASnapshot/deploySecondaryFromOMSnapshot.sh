#!/usr/bin/env bash

export opsManagerUrl="$(cat ./ops-manager.uri)"
export USERNAME="$(cat ./api.user)"
export APIKEY="$(cat ./api.key)"

# Ops Manager API endpoint
AP="/api/public/v1.0"

# Project ID
GroupId="5d6ea5b9abfe58358fb7969e"

# Replica Set ID - a replica set or a shard from a sharded cluster
# Usually the last parameter in OM UI link
rsId="5d6eda78abfe58358fb7e5c7" # shard - myReplicaSet
#rsId="5d715da1abfe582dafaaeb45" # shard - myReplicaSet_1
#rsId="5d71823fabfe5864c83381d5" # rs

myHostname="$(hostname -f)" # Deploying locally

dbPathBase="/data"
tcpPort=27017
mongodUser="mongod"
currentUser="$(whoami)"

#############################################

if ! which jq >/dev/null; then
  echo "jq binary is missing, please install it from EPEL or from here: http://stedolan.github.io/jq/"
  exit 1
else
  jq="$(which jq) -r"
fi

if [[ $mongodUser != $currentUser ]]; then
  sudo="sudo -u ${mongodUser}"
  $sudo id | grep "$mongodUser" >/dev/null || { echo "It seems that the $currentUser user doesn't have sudo privileges to run commands as $mongodUser user."; echo "This script is designed to run with unrestricted sudo access OR as ${mongodUser} user account"; exit 1; }
else
  sudo=""
fi

function sudo_wrapper() {
  $sudo "$@"
  return $?
}

function has_automation_completed() {
  local automationGoalReached="$(./om-api.sh "$AP/groups/$GroupId/automationStatus" | $jq '.goalVersion as $goal | .processes | map(.lastGoalVersionAchieved) | unique | if length == 1 and .[0] == $goal then true else false end')"
  if [[ $automationGoalReached == "true" ]]; then
    return 0
  else
    return 1
  fi
}

function wait_for_automation() {
  local timeout_seconds="$1"
  local recheck_after_seconds="$2"
  local start_time="$(date +%s)"
  echo -n "Waiting for Ops Manager automation (timeout=$timeout_seconds, interval=$recheck_after_seconds): "
  while [[ "$(($(date +%s) - $start_time))" -lt $timeout_seconds ]]; do
    if has_automation_completed; then
      echo " completed"
      return 0
    else
      echo -n "."
      sleep $recheck_after_seconds
    fi
  done
  echo ""
  echo "Timed out waiting for automation"
  exit 1
}

deploymentType="$(./om-api.sh "$AP/groups/$GroupId/clusters/$rsId" | $jq '.typeName')"
echo "Deployment is: $deploymentType"

if [[ $deploymentType == 'SHARDED_REPLICA_SET' ]]; then
  echo "Please pick a specific shard instead of an entire sharded deployment!"
  exit 0
elif [[ $deploymentType == 'REPLICA_SET' ]]; then
  ReplicaSet="$(./om-api.sh "$AP/groups/$GroupId/clusters/$rsId" | $jq '.replicaSetName')"
else
  echo "$deploymentType topology is unsupported at the moment"
  exit 1
fi
echo "Replica set we will be working on: $ReplicaSet"
echo "Replica set ID: ${rsId}"

nrOfCompletedSnapshots="$(./om-api.sh "$AP/groups/$GroupId/clusters/$rsId/snapshots" | $jq '.results | map(select(.complete == true)) | sort_by(.created.date) | length')"

if [[ $nrOfCompletedSnapshots -eq 0 ]]; then
  echo "The $ReplicaSet doesn't have any completed snapshots available, giving up..."
  exit 1
else
  echo "The $ReplicaSet has $nrOfCompletedSnapshots completed snapshots available, choosing the latest one by date"
  snapshotId="$(./om-api.sh "$AP/groups/$GroupId/clusters/$rsId/snapshots" | $jq '.results | map(select(.complete == true)) | sort_by(.created.date) | .[-1].id')"
  snapshotCreatedAt="$(./om-api.sh "$AP/groups/$GroupId/clusters/$rsId/snapshots/$snapshotId" | $jq '.created.date')"
  snapshotMongodVersion="$(./om-api.sh "$AP/groups/$GroupId/clusters/$rsId/snapshots/$snapshotId" | $jq '.parts[0].mongodVersion')"
 
  echo "Snapshot ID: $snapshotId, created on $snapshotCreatedAt, mongod version $snapshotMongodVersion"
fi

automationAgentCountOnLocal="$(./om-api.sh "$AP/groups/$GroupId/agents/AUTOMATION?pageNum=1&itemsPerPage=100" | $jq '.results | map(select(.typeName == "AUTOMATION" and .hostname == "'"$myHostname"'")) | length')"

if [[ $automationAgentCountOnLocal -ne 1 ]]; then
  echo "Can not find myself ($myHostname) in the project $GroupId among automation agents"
  exit 1
fi

seedSequence="$(date +%Y%m%d_%H%M)"
newReplicaSetMemberName="${ReplicaSet}_${seedSequence}"
dbPath="${dbPathBase}/${newReplicaSetMemberName}"

# Creating a manual restore job
restoreJobResponseFile="$(mktemp restoreJob-XXXXXXXX.json)"
./om-api.sh POST "$AP/groups/$GroupId/clusters/${rsId?}/restoreJobs?pretty=true" '{ "delivery" : { "expirationHours" : "1", "maxDownloads" : "1", "methodName" : "HTTP" }, "snapshotId" : "'"$snapshotId"'" }' > "$restoreJobResponseFile"

hasErrorCode="$($jq 'has("error")' "$restoreJobResponseFile")"
if [[ $hasErrorCode == "true" ]]; then
  echo "Creating a manual restore job failed:"
  $jq .detail "$restoreJobResponseFile"
  exit 1
fi

echo "Creating the $dbPath directory"
sudo_wrapper mkdir -p "$dbPath"
echo "Downloading the snapshot to the $dbPath directory"
snapshotUrl="$($jq '.results[0].delivery.url' "$restoreJobResponseFile")"
snapshotFile="$dbPath/snapshot.tar"
sudo_wrapper curl --progress-bar -fkLS -o "$snapshotFile" "$snapshotUrl" || { echo "Download failed, aborting..."; exit 1; };
echo "Unpacking the snapshot..."
sudo_wrapper tar xf "$snapshotFile" -C "$dbPath" --strip-components=1
sudo_wrapper rm -f "$snapshotFile"

automationConfigFile="$(mktemp automationConfig-XXXXXXXX.json)"
automationConfigUpdatedFile="$(mktemp automationConfig-XXXXXXXX.json)"
automationConfigUpdateResultFile="$(mktemp automationConfigUpdateResult-XXXXXXXX.json)"

echo "Deploying a new standalone MongoDB Server"

# Getting the current automation config
./om-api.sh "$AP/groups/$GroupId/automationConfig" > "$automationConfigFile"

# Constructing the query for the jq utility to add a new standalone host based on the first replica set member's configuration
# Feel free to customize the configuration here
# For example: if you don't name your net.ssl.PEMKeyFile the same way on all replica set hosts (server.pem), adjust it here
query='. as $root |' # save the document to the $root variable
query+='.processes |' # take the subdocument from automation config
query+='map(select(.args2_6.replication.replSetName == "'"$ReplicaSet"'")) |' # only consider "our" replica set members
query+='.[0] |' # take the first (arbitrary) replica set member - assuming that they're homogenious
query+='. |= del(.args2_6.replication) |' # delete the replication section -> convertion to a standalone
query+='(. * { args2_6: {net: {port: '"$tcpPort"'}, setParameter: { disableLogicalSessionCacheRefresh: true}, storage: {dbPath: "'"$dbPath"'"}, systemLog: {path: "'"$dbPath"'/mongodb.log"}}, hostname: "'"$myHostname"'", manualMode: false, name: "'"$newReplicaSetMemberName"'"}) as $standalone |' # merge-in the required settings. Everything else will be inherited from the picked member (SSL, etc) and place it into the $standalone variable
query+='$root |' # emit the original document
query+='.processes += [$standalone]' # add new managed member
$jq "$query" "$automationConfigFile" > "$automationConfigUpdatedFile"

./om-api.sh PUT "$AP/groups/$GroupId/automationConfig" "@$automationConfigUpdatedFile" > "$automationConfigUpdateResultFile"
hasErrorCode="$($jq 'has("error")' "$automationConfigUpdateResultFile")"
if [[ $hasErrorCode == "true" ]]; then
  echo "Deployment of a new standalone host failed:"
  $jq .detail "$automationConfigUpdateResultFile"
  echo "The original config: $automationConfigFile"
  echo "jq query: $query"
  echo "The proposed config: $automationConfigUpdatedFile"
  exit 1
else
  wait_for_automation 600 5
fi

# Let's find the compatible MongoDB Shell
# ps -q $(pidof mongod) -ho args | cut -d' ' -f1
downloadBase="$(./om-api.sh "$AP/groups/$GroupId/automationConfig" | $jq .options.downloadBase)"
mongodVersion="$(./om-api.sh "$AP/groups/$GroupId/automationConfig" | $jq '.processes | map(select(.name == "'"$newReplicaSetMemberName"'")) | .[0].version')"
mongodb_shell="$downloadBase/mongodb-linux-$(uname -m)-$mongodVersion/bin/mongo"
if [[ ! -f $mongodb_shell ]]; then
  echo "Can't find MongoDB Shell: $mongodb_shell"
  exit 1
fi

hasKeyFile="$($jq '.processes | map(select(.name == "'"$newReplicaSetMemberName"'")) | .[0].args2_6.security | has("keyFile")' "$automationConfigUpdatedFile")"
clusterAuthMode="$($jq '.processes | map(select(.name == "'"$newReplicaSetMemberName"'")) | .[0].args2_6.security.clusterAuthMode' "$automationConfigUpdatedFile")"
if [[ $hasKeyFile == "true" ]]; then
  keyFile="$($jq '.processes | map(select(.name == "'"$newReplicaSetMemberName"'")) | .[0].args2_6.security.keyFile' "$automationConfigUpdatedFile")"
fi

sslEnabled="$($jq '.ssl | has("CAFilePath")' "$automationConfigUpdatedFile")"
if [[ $sslEnabled == "true" ]]; then
  sslCAFile="$($jq '.ssl.CAFilePath' "$automationConfigUpdatedFile")"
  sslMode="$($jq '.processes | map(select(.name == "'"$newReplicaSetMemberName"'")) | .[0].args2_6.net.ssl.mode' "$automationConfigUpdatedFile")"
  sslPEMKeyFile="$($jq '.processes | map(select(.name == "'"$newReplicaSetMemberName"'")) | .[0].args2_6.net.ssl.PEMKeyFile' "$automationConfigUpdatedFile")"
fi

mongo_shell_arguments=""

if [[ $sslEnabled == true && $sslMode =~ ^requireSSL|preferSSL$ ]]; then
  mongo_shell_arguments+="--ssl --sslCAFile $sslCAFile --sslPEMKeyFile $sslPEMKeyFile "
fi

if   [[ $hasKeyFile == true && $clusterAuthMode =~ ^null|keyFile|sendKeyFile|sendX509$ ]]; then
  keyFilePassword="$(sudo_wrapper cat "$keyFile" | tr -d '\011-\015\040')"
  mongo_shell_arguments+="-u __system -p $keyFilePassword --authenticationDatabase local"
elif [[ $sslEnabled == true && $clusterAuthMode == "x509" ]]; then
  mongo_shell_arguments+="--authenticationMechanism MONGODB-X509 --authenticationDatabase=\$external"
fi

# Seeding the oplog entry
rsMemberHost="$($jq '.processes | map(select(.args2_6.replication.replSetName == "'"$ReplicaSet"'")) | .[0].hostname' "$automationConfigUpdatedFile")"
rsMemberPort="$($jq '.processes | map(select(.args2_6.replication.replSetName == "'"$ReplicaSet"'")) | .[0].args2_6.net.port' "$automationConfigUpdatedFile")"
uri="mongodb://$rsMemberHost:$rsMemberPort/?replicaSet=$ReplicaSet"
oplogSizeBytes="$(sudo_wrapper $mongodb_shell --quiet $mongo_shell_arguments --eval "db.getSiblingDB('local').oplog.rs.stats().maxSize" "$uri" | fgrep -v ' I NETWORK  [')" # https://jira.mongodb.org/browse/SERVER-27159
hasSessionsCollection="$(sudo_wrapper $mongodb_shell --quiet $mongo_shell_arguments --eval "db.getSiblingDB('config').runCommand({ listCollections: 1, filter: { name: 'system.sessions' }, nameOnly: true}).cursor.firstBatch.length" "$uri" | fgrep -v ' I NETWORK  [')" # https://jira.mongodb.org/browse/SERVER-27159
if [[ $hasSessionsCollection == "1" ]]; then
  sessionsCollectionUUID="$(sudo_wrapper $mongodb_shell --quiet $mongo_shell_arguments --eval 'db.getSiblingDB("config").getCollectionInfos({name: "system.sessions"})[0].info.uuid' "$uri" | fgrep -v ' I NETWORK  [')"
  sessionsCollectionIdIndex="$(sudo_wrapper $mongodb_shell --quiet $mongo_shell_arguments --eval 'JSON.stringify(db.getSiblingDB("config").getCollectionInfos({name: "system.sessions"})[0].idIndex)' "$uri" | fgrep -v ' I NETWORK  [')"
fi
transactionsCollectionUUID="$(sudo_wrapper $mongodb_shell --quiet $mongo_shell_arguments --eval 'db.getSiblingDB("config").getCollectionInfos({name: "transactions"})[0].info.uuid' "$uri" | fgrep -v ' I NETWORK  [')"
transactionsCollectionIdIndex="$(sudo_wrapper $mongodb_shell --quiet $mongo_shell_arguments --eval 'JSON.stringify(db.getSiblingDB("config").getCollectionInfos({name: "transactions"})[0].idIndex)' "$uri" | fgrep -v ' I NETWORK  [')"
logicalSessionsTimeoutMinutes="$(sudo_wrapper $mongodb_shell --quiet $mongo_shell_arguments --eval 'db.adminCommand({getParameter: 1, localLogicalSessionTimeoutMinutes: ""}).localLogicalSessionTimeoutMinutes' "$uri" | fgrep -v ' I NETWORK  [')"
logicalSessionsTimeoutSeconds="$(($logicalSessionsTimeoutMinutes * 60))"
seedEntry="$(sudo_wrapper cat "$dbPath/seedSecondary.sh" | egrep '^mongo ' | sed 's,^.*throw res.errmsg;} else{,,; s,;if (.*$,,')"

echo "Oplog size from $rsMemberHost:$rsMemberPort is $oplogSizeBytes"
echo "logicalSessionsTimeoutSeconds  : $logicalSessionsTimeoutSeconds"
if [[ $hasSessionsCollection == "1" ]]; then
  echo "system.sessions collection UUID: $sessionsCollectionUUID"
fi
echo "transactions    collection UUID: $transactionsCollectionUUID"
echo "Oplog seed from the snapshot   : $seedEntry"

standalone="mongodb://$myHostname:$tcpPort/"
echo "Mangling standalone's data on $standalone :"

echo "Creating the oplog.rs collection:"
sudo_wrapper $mongodb_shell --quiet $mongo_shell_arguments --eval "db.getSiblingDB('local').runCommand({ create: 'oplog.rs', capped: true, size: $oplogSizeBytes})" "$standalone"

echo "Seeding the oplog using the snapshot's data:"
sudo_wrapper $mongodb_shell --quiet $mongo_shell_arguments --eval "$seedEntry" "$standalone"

echo "Creating a single-node replica set"
sudo_wrapper $mongodb_shell --quiet $mongo_shell_arguments --eval "db.getSiblingDB('local').system.replset.insert({'_id' : '$ReplicaSet','version' : 1,'members' : [{'_id' : 0,'host' :'$myHostname:$tcpPort'}],'settings' : {}})" "$standalone"

if [[ $hasSessionsCollection == "1" ]]; then
  echo "Creating the config.system.sessions collection:"
  sudo_wrapper $mongodb_shell --quiet $mongo_shell_arguments --eval 'db.getSiblingDB("config").runCommand({applyOps: [{ op: "c", ns: "config.$cmd", ui: '"$sessionsCollectionUUID"', o: { create: "system.sessions", idIndex: '"$sessionsCollectionIdIndex"' }}]})' "$standalone"

  echo "Creating the TTL index in the config.system.sessions collection:"
  sudo_wrapper $mongodb_shell --quiet $mongo_shell_arguments --eval 'db.getSiblingDB("config").system.sessions.createIndex({lastUse: 1}, {name: "lsidTTLIndex", expireAfterSeconds: NumberInt('"$logicalSessionsTimeoutSeconds"')})' "$standalone"
fi

echo "Creating the config.transactions collection:"
sudo_wrapper $mongodb_shell --quiet $mongo_shell_arguments --eval 'db.getSiblingDB("config").runCommand({applyOps: [{ op: "c", ns: "config.$cmd", ui: '"$transactionsCollectionUUID"', o: { create: "transactions", idIndex: '"$transactionsCollectionIdIndex"' }}]})' "$standalone"

echo "Performing fall-from-the-cliff check"
earliestTsInPrimaryOplog="$(sudo_wrapper $mongodb_shell --quiet $mongo_shell_arguments --eval 'DB.tsToSeconds(db.getSiblingDB("local").oplog.rs.find().sort({$natural: 1}).limit(1).next().ts)' "$uri" | fgrep -v ' I NETWORK  [')"
if [[ $seedEntry =~ \*[[:space:]]([[:digit:]]+), ]]; then
  snapshotLastOpTime="${BASH_REMATCH[1]}"
else
  echo "Can't extract last OpTime from the seed entry!"
  exit 1
fi
if [[ $earliestTsInPrimaryOplog -gt $snapshotLastOpTime ]]; then
  echo "ERROR: The snapshot is too old to be restored."
  echo "Primary earliest oplog entry: $(date --date=@$earliestTsInPrimaryOplog)"
  echo "Snapshot's last opTime      : $(date --date=@$snapshotLastOpTime)"
  echo "Consider the following:"
  echo "1. Wait for a fresh snapshot"
  echo "2. Increase primary's oplog size"
  exit 1
fi

echo "Adding the standalone to the $ReplicaSet replica set"
rsAddConfigUpdatedFile="$(mktemp automationConfig-XXXXXXXX.json)"
rsAddConfigUpdateResultFile="$(mktemp automationConfigUpdateResult-XXXXXXXX.json)"
$jq --arg name "$newReplicaSetMemberName" --arg rsName "$ReplicaSet" 'del(.processes[] | select(.name == $name).args2_6.setParameter.disableLogicalSessionCacheRefresh) | (.processes[] | select(.name == $name)).args2_6.replication.replSetName = $rsName | . as $updated | .replicaSets | map(select(._id == $rsName)) | .[0].members | (max_by(._id)._id + 1) as $i | {"_id": $i, "arbiterOnly": false, "buildIndexes": true, "hidden": true, "host": $name, "priority": 0, "slaveDelay": 0, "votes": 0} as $newMember | $updated | (.replicaSets[] | select(._id == $rsName)).members += [$newMember]' "$automationConfigUpdatedFile" > "$rsAddConfigUpdatedFile"
./om-api.sh PUT "$AP/groups/$GroupId/automationConfig" "@$rsAddConfigUpdatedFile" > "$rsAddConfigUpdateResultFile"
hasErrorCode="$($jq 'has("error")' "$rsAddConfigUpdateResultFile")"
if [[ $hasErrorCode == "true" ]]; then
  echo "Conversion of the standalone to a new replica set member failed:"
  $jq .detail "$rsAddConfigUpdateResultFile"
  echo "The proposed config: $rsAddConfigUpdatedFile"
  exit 1
else
  wait_for_automation 600 5
fi

echo "$(date): Waiting for $logicalSessionsTimeoutSeconds seconds to unhide the secondary..."
sleep $logicalSessionsTimeoutSeconds

echo "Making the new replica set member visible"
rsReconfigUpdatedFile="$(mktemp automationConfig-XXXXXXXX.json)"
rsReconfigUpdateResultFile="$(mktemp automationConfigUpdateResult-XXXXXXXX.json)"
./om-api.sh "$AP/groups/$GroupId/automationConfig" | $jq --arg name "$newReplicaSetMemberName" --arg rsName "$ReplicaSet" '((.replicaSets[] | select(._id == $rsName)).members[] | select(.host == $name)).priority = 1 | ((.replicaSets[] | select(._id == $rsName)).members[] | select(.host == $name)).votes = 1 | ((.replicaSets[] | select(._id == $rsName)).members[] | select(.host == $name)).hidden = false' > "$rsReconfigUpdatedFile"
./om-api.sh PUT "$AP/groups/$GroupId/automationConfig" "@$rsReconfigUpdatedFile" > "$rsReconfigUpdateResultFile"
hasErrorCode="$($jq 'has("error")' "$rsReconfigUpdateResultFile")"
if [[ $hasErrorCode == "true" ]]; then
  echo "Conversion of the standalone to a new replica set member failed:"
  $jq .detail "$rsReconfigUpdateResultFile"
  echo "The proposed config: $rsReconfigUpdatedFile"
  exit 1
else
  wait_for_automation 600 5
fi

echo "Cleaning up temporary files"
[[ -f "$automationConfigFile" ]]             && rm -f "$automationConfigFile"
[[ -f "$rsReconfigUpdatedFile" ]]            && rm -f "$rsReconfigUpdatedFile"
[[ -f "$restoreJobResponseFile" ]]           && rm -f "$restoreJobResponseFile"
[[ -f "$rsAddConfigUpdatedFile" ]]           && rm -f "$rsAddConfigUpdatedFile"
[[ -f "$rsReconfigUpdateResultFile" ]]       && rm -f "$rsReconfigUpdateResultFile"
[[ -f "$rsAddConfigUpdateResultFile" ]]      && rm -f "$rsAddConfigUpdateResultFile"
[[ -f "$automationConfigUpdatedFile" ]]      && rm -f "$automationConfigUpdatedFile"
[[ -f "$automationConfigUpdateResultFile" ]] && rm -f "$automationConfigUpdateResultFile"
echo "DONE"
