set -euo pipefail

if [ "$#" -ne 2 ]; then
  printf 'usage: %s CHANGELOG VERSION\n' "$0" >&2
  exit 2
fi

changelog=$1
version=$2

case $version in
  ""|*[!0-9.]*)
    printf 'version must be numbers separated by dots: %s\n' "$version" >&2
    exit 2
    ;;
esac

if [ ! -f "$changelog" ]; then
  printf 'changelog not found: %s\n' "$changelog" >&2
  exit 1
fi

escaped=$(printf '%s' "$version" | sed 's/\./\\./g')

set +e
notes=$(awk -v version="$escaped" '
BEGIN {
  heading = "^## \\[" version "\\] - [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][ \t]*$"
  stop = "^## \\["
}
$0 ~ heading {
  if (found) {
    dup = 1
  }
  found = 1
  capture = 1
  count = 0
  next
}
capture && $0 ~ stop {
  capture = 0
  next
}
capture {
  count++
  lines[count] = $0
}
END {
  if (dup) {
    exit 4
  }
  if (!found) {
    exit 3
  }
  start = 1
  end = count + 0
  while (start <= end && lines[start] ~ "^[ \t]*$") {
    start++
  }
  while (end >= start && lines[end] ~ "^[ \t]*$") {
    end--
  }
  if (start > end) {
    exit 5
  }
  for (i = start; i <= end; i++) {
    print lines[i]
  }
}
' "$changelog")
status=$?
set -e

if [ "$status" -eq 4 ]; then
  printf 'changelog has more than one section for %s\n' "$version" >&2
  exit 1
fi
if [ "$status" -eq 5 ]; then
  printf 'changelog section for %s is empty\n' "$version" >&2
  exit 1
fi
if [ "$status" -ne 0 ]; then
  printf 'changelog section for %s is missing\n' "$version" >&2
  exit 1
fi
if [ -z "$notes" ]; then
  printf 'changelog section for %s is empty\n' "$version" >&2
  exit 1
fi

printf '%s\n' "$notes"
