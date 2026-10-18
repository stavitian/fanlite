# Firmar y notarizar FanLite

La compilación selecciona automáticamente un certificado Developer ID Application si hay uno solo en el llavero. La firma lleva Hardened Runtime y una marca de tiempo segura. Para elegir otro certificado, pasá su nombre o huella mediante SIGNING_IDENTITY. Si no hay ninguno, se avisa y se usa firma ad-hoc, que no sirve para notarizar.

## 1. Compilar y firmar

En este Mac, el Team ID del certificado Developer ID es Q5YPS3XF9A:

```sh
cd ~/projects/fanlite
SIGNING_IDENTITY="Developer ID Application: santiago Tavitian (Q5YPS3XF9A)" scripts/build_app.sh
codesign --verify --deep --strict --verbose=2 build/FanLite.app
codesign -dv --verbose=4 build/FanLite.app
mkdir -p dist
ditto -c -k --keepParent build/FanLite.app dist/FanLite-1.0.0-notarization.zip
```

La salida debe incluir Authority=Developer ID Application, TeamIdentifier=Q5YPS3XF9A, flags con runtime y Timestamp. La app no usa App Sandbox ni necesita excepciones de Hardened Runtime para su código nativo actual.

## 2. Guardar las credenciales en el llavero (una vez)

Creá una contraseña específica de aplicación en https://account.apple.com, en Inicio de sesión y seguridad → Contraseñas de aplicación. No es la contraseña normal de tu cuenta. Ejecutá:

```sh
xcrun notarytool store-credentials "fanlite-notary" --team-id Q5YPS3XF9A
```

La herramienta pregunta por el Apple ID y la contraseña específica de aplicación y valida las credenciales. Introducilos en tu Terminal; no hace falta compartirlos en el chat. El Apple ID debe tener acceso al equipo Q5YPS3XF9A.

## 3. Enviar a Apple

```sh
cd ~/projects/fanlite
xcrun notarytool submit dist/FanLite-1.0.0-notarization.zip --keychain-profile "fanlite-notary" --wait
```

Esperá a que indique `status: Accepted`. Guardá el identificador de la solicitud. Si el resultado es Invalid, descargá el informe sustituyendo ID_SOLICITUD por el identificador recibido:

```sh
xcrun notarytool log ID_SOLICITUD --keychain-profile "fanlite-notary" dist/notarization-log.json
```

Si se interrumpe la espera, la solicitud sigue en Apple. Podés consultar su estado con `xcrun notarytool info ID_SOLICITUD --keychain-profile "fanlite-notary"` y esperar con `xcrun notarytool wait ID_SOLICITUD --keychain-profile "fanlite-notary"`.

## 4. Adjuntar el ticket y preparar la descarga

Solo después de Accepted, y sobre la misma app enviada, sin recompilar ni volver a firmarla:

```sh
xcrun stapler staple build/FanLite.app
xcrun stapler validate build/FanLite.app
codesign --verify --deep --strict --verbose=2 build/FanLite.app
spctl --assess --type execute --verbose=4 build/FanLite.app
scripts/make_dmg.sh
```

La evaluación debe indicar `accepted` y `source=Notarized Developer ID`. El último paso regenera dist/FanLite-1.0.0.zip, dist/FanLite-1.0.0.dmg y SHA256SUMS.txt con la app que ya contiene el ticket. No uses `--build` en este paso: una compilación nueva requiere otra notarización. El ZIP de envío no recibe el ticket automáticamente; distribuí los paquetes regenerados al final. Los archivos de distribución anteriores a este proceso siguen sin notarizar.

La notarización evita el bloqueo por desarrollador sin verificar cuando el Mac permite apps de desarrolladores identificados. Puede mantenerse la confirmación habitual de primera apertura. El permiso de administrador para controlar ventiladores es independiente.

Referencias de Apple:
- https://developer.apple.com/developer-id/
- https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
- https://developer.apple.com/documentation/security/customizing-the-notarization-workflow
