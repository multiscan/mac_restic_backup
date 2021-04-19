#!/bin/sh
prg="$(/usr/local/bin/greadlink -f $0)"
casa=$(dirname $(/usr/local/bin/greadlink -f $0))
export LOGFILE="$casa/log"

name="giova.restic.backup"
laconf="$HOME/Library/LaunchAgents/$name.plist"
interval=3600

usage() {
  cat <<-__EOF
    go.sh [-t INTERVAL] [COMMAND]
    where 
      INTERVAL is every how many seconds the script have to run (default 3600)
      COMMAND  is one of the following
        start:   setup system cron job to start the backup every INTERVAL seconds
        stop:    stop running the backup and remove configuration from sytem cron
        restart: equivalent to start and the stop
        status:  print current configuration 
        run:     execute the backup now independently of the periodic execution 
                 configuration
        list:    List current list of snapshots
        if command is not provided, "run" is assumed.
__EOF
}

start() {
  if [ ! -f $laconf ] ; then
    echo "Configuring $name with interval of $interval seconds"
    cat > $laconf <<-____EOF
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
        <key>Label</key>
        <string>$name</string>
        <key>ProgramArguments</key>
        <array>
          <string>/usr/local/bin/bash</string>
          <string>-c</string>
          <string>$prg</string>
        </array>
        <key>StartInterval</key>
        <integer>$interval</integer>
      </dict>
      </plist>    
____EOF
  fi
  echo "Registering $name service"
  launchctl list | grep -q "$name"  || launchctl load -w $laconf
}

stop() {
  echo "Unregistering $name service"
  launchctl remove $name
  rm -f $laconf  
}

status() {
  launchctl list "$name" 2> /dev/null
  if [ $? -eq 0 ] ; then
    echo "Installed"
  else
    echo "Not installed"
  fi
}

restart() {
  stop
  sleep 2
  start
}

run() {
  cd $casa
  /usr/bin/ruby $casa/restic.rb -n -v -v backup
}

list() {
  /usr/bin/ruby $casa/restic.rb list
  echo "For infos about snapshots, please use the 'inspect' command"
}

inspect() {
  /usr/bin/ruby $casa/restic.rb inspect
}

cmd="run"
while [ $# -gt 0 ] ; do
case $1 in
-t) 
  interval=$2
  shift 2
  ;;
-h) 
  usage
  shift 1
  exit
  ;;
start|stop|restart|status|run|list|inspect)
  cmd=$1
  shift 1
  ;;
*)
  echo "Unrecognized option $1"
  usage
  exit
esac
done

$cmd
