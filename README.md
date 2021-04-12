# Giova restic backup
Simple script to execute periodic backup of selected directories on a laptop
running OsX. 
This does nothing else than mounting an external disk if it is attached and
executing restic to run the backup.
The logic for installing a `launchctl` periodic execution is provided with the
`go.sh` driver script.

## Prerequisites
The script assumes the following things to be present in the laptop:
 * a recent ruby interpreter. The default one coming with osx should be enough;
 * [restic](https://restic.net/);
 * [brew](https://brew.sh/) unless you get rid of the following dependency;
 * `greadlink` which is installed with `brew install coreutils`;
 * _optional_: [keybase](https://keybase.io/);
 * _optional_: [jq](https://stedolan.github.io/jq/) which can be installed with
               `brew install jq`
 * One or more external disk with APFS volume partitioning.
 
## Setup
You should create your own `backups.yml` and `excludes.txt` files by copying and
adapting the provided examples. Restic inevitably creates encrypted backups.
The encryption key is provided as `RESTIC_PASSWORD` environment variable. 
In my case, as you will notice from the example, the password is written on a 
yaml file (`passfile` in `backups.yml`) which is stored in my keybase filesystem.

## Execute
Everything is done with the `go.sh` script.

To run the backup on demand by hand just run `go.sh` without other options.
To install (uninstall) a periodic task, run `go.sh start` (`go.sh stop`).
