# Downloaded human avatar

CoachMe uses Blender Studio’s existing **GEO-body_male_realistic** mesh and eyes from Human Base Meshes v1.2.0, released under **CC0 1.0**. No procedural body geometry is generated.

Official source and license listing: https://www.blender.org/download/demo-files/
Archive: https://download.blender.org/demo/asset-bundles/human-base-meshes/human-base-meshes-bundle-v1.2.0.zip
Downloaded 2026-09-11; archive SHA-256: `b7421350cbad8425dd1ba93c4248867a1c236cc8a3a3dc140d4c2a03144c4bad`.
License: https://creativecommons.org/publicdomain/zero/1.0/

The downloaded base mesh has no rig. The conversion adds 15 anatomical display bones with Blender heat weights, maps the surface to the fixed CoachMe bind proportions, subdivides once, and exports 46,698 vertices / 93,384 triangles with four normalized influences. It preserves the original mesh topology and facial/body detail. Eyes follow the head. The model is rendered blue/translucent in SceneKit with optional illustrative inner structure.

## Rebuild

Unzip the official archive, then run from the repository:

```sh
/Applications/Blender.app/Contents/MacOS/Blender --background --python tools/avatar/bind_downloaded_avatar.py -- /path/to/human_base_meshes_bundle.blend tools/avatar/rest.json /tmp/coachme-avatar
```

Copy the resulting `GolfAvatar.mesh.json` into `CoachMe/Resources`. The script also saves an editable rigged `.blend` and a standard-address preview. `export_rest.swift` exports the shared bind and preview joint positions.

## Motion behavior

`GolfAvatarPose` maps world-landmark directions to fixed limb lengths and shoulder/hip widths. Missing or invalid coordinates fall back to template directions. Display limits bound torso tilt/twist and joint flexion; the same anatomical across-axis controls limb roll to avoid twisted knees. Raw landmarks and metrics are unchanged. This is a visualization of estimated motion, not calibrated motion capture or a professionally validated swing reference. Hands have no separately tracked finger rig. The club is shown only in the standard address, as a demonstration.

Core tests cover fixed lengths, missing legs, invalid input and deterministic seeking. `AvatarRenderingTests` checks the bundled skin/bone binding and renders actual SceneKit previews. Normal rendering tests make no AI API requests.
