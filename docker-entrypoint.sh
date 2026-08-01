#!/bin/sh
set -eu

/app/bin/floor_control eval "FloorControl.Release.migrate()"
exec /app/bin/floor_control start
