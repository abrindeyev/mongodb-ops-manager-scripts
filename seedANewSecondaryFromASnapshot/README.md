This Bash script deploys a new secondary in a replica set or a shard using a snapshot instead of performing an initial sync procedure.

The script was tested using Ops Manager 4.0.12 and MongoDB Server versions 3.6 and 4.0

## Assumptions

1. The script is supposed to run on the host where the new secondary will be deployed.
2. The MongoDB deployment is using Ops Manager automation.
3. We assume unrestricted `sudo` access. Alternatively, you can run this as under the same user account as MongoDB Server is using (usually `mongod`).
4. The `dbPath` **must** have enough space to store the compressed and uncompressed snapshot from the given replica set.
5. The script uses the `jq` utility to parse JSON responses from Ops Manager API.
6. The oplog size for the new replica set member is copied from the current primary.
7. The MongoDB Server version is copied from the first replica set member in the API response.
8. The script uses the latest completed snapshot by date.
9. Every effort was made to support various deployments, but I limited the testing to the following deployment configuration:
   - MongoDB Enterprise Server `3.6.14` and `4.0.12`,
   - SSL enabled and set to `requireSSL`,
   - `MONGODB-X509` authentication mechanism enabled.

## Setup

1. Make sure that the `jq`, `tar`, `sudo`, `curl` commands are installed.
2. Place both scripts to the same directory.
3. Edit the top of the `deploySecondaryFromOMSnapshot.sh` script:
   - `GroupId` - target replica set / shard id. For example: `5d71823fabfe5864c83381d5`. It's usually the last parameter in the Ops Manager URL when you descend to a specific replica set.
   - `dbPathBase` - the directory where the new replica set member will be created.
   - `tcpPort` - TCP port number for a new replica set member.
   - `mongodUser` - the UNIX account which is used by MongoDB Automation Agent and Server instances.
4. Configure Ops Manager API:
   - Allow access (whitelist) from the current host.
   - Create the `ops-manager.uri` file and place the Ops Manager URI there. For example: `http://ec2-1-2-3-4.us-west-1.compute.amazonaws.com:8080`
   - Create the `api.user` file and place the Ops Manager account name there. For example: `john.doe@host.tld`
   - Create the `api.key` file and place the API key for the account above there. For example: `abcdef12-abc0-def9-a318-abcdef123456`
5. Run the `deploySecondaryFromOMSnapshot.sh` script. For example:

```
$ ./deploySecondaryFromOMSnapshot.sh
Deployment is: REPLICA_SET
Replica set we will be working on: myReplicaSet_1
Replica set ID: 5d715da1abfe582dafaaeb45
The myReplicaSet_1 has 11 completed snapshots available, choosing the latest one by date
Snapshot ID: 5d7bf08dabfe5874bbd3d858, created on 2019-09-13T19:38:45Z, mongod version 3.6.14
Creating the /data/myReplicaSet_1_20190913_2034 directory
Downloading the snapshot to the /data/myReplicaSet_1_20190913_2034 directory
######################################################################## 100.0%
Unpacking the snapshot...
Deploying a new standalone MongoDB Server
Waiting for Ops Manager automation (timeout=600, interval=5): .... completed
Oplog size from ip-172-31-25-35.us-west-1.compute.internal:27017 is NumberLong("10737418240")
logicalSessionsTimeoutSeconds  : 1800
system.sessions collection UUID: UUID("18ff8004-8709-4bc7-8ec0-0cffe4a763da")
transactions    collection UUID: UUID("19d3bef4-4091-4143-886a-69dd4dbeebb2")
Oplog seed from the snapshot   : db.getSiblingDB('local').oplog.rs.insert({ts : Timestamp((db.version().match(/^2\.[012]/) ? 1000 : 1) * 1568403554, 1), h : NumberLong('-8561801763336730344'), t : NumberLong('3'), op : 'n', ns : '', o : { msg : 'seed from backup service' }})
Mangling standalone's data on mongodb://ip-172-31-31-150.us-west-1.compute.internal:27028/ :
Creating the oplog.rs collection:
{ "ok" : 1 }
Seeding the oplog using the snapshot's data:
WriteResult({ "nInserted" : 1 })
Creating the config.system.sessions collection:
{ "applied" : 1, "results" : [ true ], "ok" : 1 }
Creating the TTL index in the config.system.sessions collection:
{
        "createdCollectionAutomatically" : false,
        "numIndexesBefore" : 1,
        "numIndexesAfter" : 2,
        "ok" : 1
}
Creating the config.transactions collection:
{ "applied" : 1, "results" : [ true ], "ok" : 1 }
Adding the standalone to the myReplicaSet_1 replica set
Waiting for Ops Manager automation (timeout=600, interval=5): .... completed
Fri Sep 13 20:35:53 UTC 2019: Waiting for 1800 seconds to unhide the secondary...
Making the new replica set member visible
Waiting for Ops Manager automation (timeout=600, interval=5): ... completed
Cleaning up temporary files
DONE
```
