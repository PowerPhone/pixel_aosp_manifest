# Parse one AoC service's Up-ring descriptor from the kernel `services`
# attribute. Output fields are:
#   slots slot_bytes capacity_bytes tx rx delta_bytes available_bytes overflow

function parse_error(message) {
  printf "error: cannot parse AoC services: %s\n", message > "/dev/stderr"
  parse_failed = 1
  exit 2
}

BEGIN {
  if (target == "")
    parse_error("target service is empty")
  uint32_modulus = 4294967296
  active = 0
  target_headers = 0
  target_up_lines = 0
}

{
  line = $0
  sub(/\r$/, "", line)

  # Any service header ends the preceding service, including a truncated or
  # otherwise malformed header at the PAGE_SIZE boundary.
  if (line ~ /^[[:space:]]*[0-9][0-9]*[[:space:]]*:/) {
    active = 0
    if (line !~ /^[[:space:]]*[0-9][0-9]*[[:space:]]*:[[:space:]]*"[^"]+"[[:space:]]+mbox[[:space:]]+-?[0-9][0-9]*[[:space:]]*$/)
      next

    name = line
    sub(/^[^"]*"/, "", name)
    sub(/".*$/, "", name)
    if (name == target) {
      active = 1
      target_headers++
    }
    next
  }

  if (active && line ~ /^[[:space:]]*Up[[:space:]]/) {
    target_up_lines++
    if (target_up_lines != 1)
      parse_error("duplicate Up ring for service " target)

    normalized = line
    sub(/^[[:space:]]*/, "", normalized)
    sub(/[[:space:]]*$/, "", normalized)
    field_count = split(normalized, fields, /[[:space:]]+/)
    if (field_count != 4 || fields[1] != "Up" ||
        fields[2] !~ /^Size:[0-9][0-9]*x[0-9][0-9]*B$/ ||
        fields[3] !~ /^Tx:[0-9][0-9]*$/ ||
        fields[4] !~ /^Rx:[0-9][0-9]*$/)
      parse_error("malformed Up ring for service " target ": " line)

    size_spec = fields[2]
    sub(/^Size:/, "", size_spec)
    sub(/B$/, "", size_spec)
    split(size_spec, dimensions, "x")
    slots = dimensions[1] + 0
    slot_bytes = dimensions[2] + 0

    tx_text = fields[3]
    sub(/^Tx:/, "", tx_text)
    tx = tx_text + 0
    rx_text = fields[4]
    sub(/^Rx:/, "", rx_text)
    rx = rx_text + 0

    if (slots <= 0 || slot_bytes <= 0)
      parse_error("non-positive Up-ring geometry for service " target)
    if (tx < 0 || tx >= uint32_modulus || rx < 0 || rx >= uint32_modulus)
      parse_error("Tx/Rx is outside uint32 range for service " target)
    if (slots > int((uint32_modulus - 1) / slot_bytes))
      parse_error("Up-ring capacity exceeds uint32 range for service " target)

    capacity = slots * slot_bytes
    delta = tx - rx
    if (delta < 0)
      delta += uint32_modulus
    overflow = (delta > capacity) ? 1 : 0
    available = overflow ? capacity : delta
  }
}

END {
  if (parse_failed)
    exit 2
  if (target_headers == 0)
    parse_error("service not found: " target)
  if (target_headers != 1)
    parse_error("duplicate service header: " target)
  if (target_up_lines != 1)
    parse_error("Up ring not found for service " target)

  printf "%.0f %.0f %.0f %.0f %.0f %.0f %.0f %d\n", \
    slots, slot_bytes, capacity, tx, rx, delta, available, overflow
}
