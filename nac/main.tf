# Cisco Network as Code for IOS-XR: the configuration is data, not resources.
# This file only points the module at the model; everything that reaches the
# routers is described in iosxr.nac.yaml.
#
# The module declares the `iosxr` provider itself, from the `devices` list in
# the YAML, and takes credentials from IOSXR_USERNAME / IOSXR_PASSWORD /
# IOSXR_TLS -- which nac.sh sets from ../topology.env.
module "iosxr" {
  source  = "netascode/nac-iosxr/iosxr"
  version = ">= 0.1.1"

  yaml_files = ["iosxr.nac.yaml"]
}
