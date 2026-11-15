# Créditos de audio

`mars_ambient_wind.mp3` — grabación real del viento en Marte, micrófono de SuperCam del rover Perseverance
(sol 4, `45828_SCAM_MIC_SOL004_RUN001`).

Crédito: **NASA/JPL-Caltech/LANL/CNES/CNRS/ISAE-Supaero, SuperCam Mars microphone.**

Se reproduce en loop continuo con el Autoload `AmbientAudio` (`ambient_audio.gd`), bus "Ambient".
Para desactivarlo en desarrollo: `godot --path viewer-godot -- --no-ambient`.

`rover_selfnoise.wav` — primeros sonidos grabados en Marte, incluye el ruido propio del rover
(`45705_1st_Sounds_from_Mars_includes_rover_self-noise`): micrófono del costado del Perseverance, 20 feb 2021.

Crédito: **NASA/JPL-Caltech.**

Se reproduce como sonido de proximidad (a menos de 5 m del rover) con el Autoload `RoverSound`
(`rover_sound.gd`), bus "Rover". Se apaga con `-- --no-ambient` y no suena con `-- --norover`.
