# docs

`IOS-XR-NAC-topology.pdf` — a three-page reference for the lab: topology
diagram, node inventory, addressing, BGP ASNs and sessions, routing policy,
management access, virtual wiring, configuration ownership and test coverage.

`topology.html` is the source. Regenerate the PDF with:

```bash
google-chrome --headless --disable-gpu --no-pdf-header-footer \
  --print-to-pdf=docs/IOS-XR-NAC-topology.pdf "file://$PWD/docs/topology.html"
```

Chrome is used rather than a Python PDF library because the diagram is inline
SVG and the layout is CSS -- both render as-authored, and the HTML can be
opened directly in a browser while editing.

Everything in it is read from `topology.env`, `configs/`, `nac/` and the live
lab, so it should be regenerated when those change.
