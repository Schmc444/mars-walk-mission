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

## Copias normalizadas (las que carga el visor)

Los originales (`mars_ambient_wind.mp3`, `rover_selfnoise.wav`) se conservan sin tocar. El visor usa copias
normalizadas, porque los originales quedaban muy bajos (viento RMS -30 dBFS, mediana -34 dBFS):

- `mars_ambient_wind_norm.wav` — copia de `mars_ambient_wind.mp3` (crédito: NASA/JPL-Caltech/LANL/CNES/CNRS/ISAE-Supaero,
  SuperCam Mars microphone). Mono (L = R en el original), sin el silencio del codificador, bucle con crossfade
  de 2 s horneado (sin salto en la costura), ganancia +6,9 dB y limitador suave: RMS -24 dBFS, pico -1 dBFS.
- `rover_selfnoise_norm.wav` — copia de `rover_selfnoise.wav` (crédito: NASA/JPL-Caltech). Ganancia +8,6 dB y
  limitador suave: RMS -13,5 dBFS, pico -1 dBFS.

Son trabajos derivados de grabaciones de NASA, procesados con numpy (sin ffmpeg). Master lleva un limitador de
seguridad (techo -1 dBFS) porque viento + rover suman picos por encima de 0 dBFS.
