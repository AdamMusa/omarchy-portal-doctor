# Compiled QML provenance

Omarchy UI generated this package's native Qt module from the tree-shaken Zui and
Omarchy host QML graph. Generated QML source contents were discarded after AOT compilation.

- Format: `qt-aot-qml-module` version 1
- Qt: `6.11.2`
- Module: `OmarchyUI.Bundles.B7e548893c2f206fd6e12`
- Source fingerprint: `7e548893c2f206fd6e124030434fa339b66b76a20f966b6b1ed965e2c99d8469`

## Artifacts

- `OmarchyUI/Bundles/B7e548893c2f206fd6e12/libomarchy_ui_bundle_b7e548893c2f206fd6e12.so` — `c0ad62703d26d38115a147a5d02335eca5d81e4fc3a844b8512dd996219a52cf`
- `OmarchyUI/Bundles/B7e548893c2f206fd6e12/libomarchy_ui_bundle_b7e548893c2f206fd6e12plugin.so` — `5ec47c2ba84309eeefe0c4b8043a512bce0351e70298fc1845ea64df573bf3b5`

Verify the packaged libraries from the plugin directory:

```bash
sha256sum --check omarchy-ui-qml-bundle.sha256
```

`App.qml`, `Service.qml`, `Panel.qml`, and `BarWidget.qml` are the minimal loader shims
required by Omarchy's file-based entry-point contract. Application UI lives in the compiled
module recorded by `omarchy-ui-qml-bundle.json`.
