#!/usr/bin/env bash

set -e

if [[ ! -z $1 ]]; then
  Url="$1"
  if [[ $Url =~ ^GET|POST|PUT|PATCH$ ]]; then
    method="$Url"
    shift
    Url="$1"
    shift
  else
    method="GET"
  fi
else
  method="GET"
  Url="$(cat -)"
fi

if [[ $Url =~ ^http ]]; then
  request="${Url}"
else
  request="${opsManagerUrl?}${Url}"
fi

if [[ $method == "GET" ]]; then
  curl -s --user "${USERNAME?}:${APIKEY?}" --digest --header 'Accept: application/json' --request "$method" "$request" 
else
  #set -x
  curl -s --user "${USERNAME?}:${APIKEY?}" --digest --header 'Accept: application/json' --header 'Content-Type: application/json' --request "$method" "$request" --data "$1"
fi
