# Run and debug the Flutter app in Android Studio

ASG is a Flutter application targeting Android, iOS, web, macOS, Windows and Linux. Included platform runners do not establish tested device support. Managed MLX setup and the current independent Flutter web generator host are macOS-specific; other platforms retain supported app features and runtime connection controls.

1. In Android Studio, use **File → Open** and select the Flutter project root, the folder containing `pubspec.yaml`:
   `/Users/arpitsinha/AndroidStudioProjects/ASG/asg`
   Opening only its `android/` subfolder does not load the shared Flutter configuration.
2. In **Settings → Plugins**, enable/install **Flutter** and its **Dart** dependency. Restart the IDE if requested.
3. In **Settings → Languages & Frameworks → Flutter**, set the Flutter SDK to `/Users/arpitsinha/flutter` on this machine. Other machines should use their own SDK location.
4. Run **Flutter Pub Get** from `pubspec.yaml`, or run `flutter pub get` in the project terminal.
5. Select **Automated Software Generator** in the run configuration dropdown. The shared `.run/Automated Software Generator.run.xml` targets `lib/main.dart`. If the project was already open, reopen it to discover the configuration.
6. Select an Android emulator or attached Android device in the Flutter device dropdown. Use **Tools → Device Manager** to create/start an emulator, or enable USB debugging on a physical device.
7. Click **Run** or **Debug**. Both use the same Flutter configuration; Debug enables Dart breakpoints and the Flutter debugger. The device is intentionally selected in the IDE rather than hardcoded in the shared configuration.

## Required Android SDK setup on this machine

The environment check found Android SDK 36 installed but **Android SDK Command-line Tools** missing and Android license status unresolved. A run configuration does not install these components.

In **Tools → SDK Manager → SDK Tools**, install **Android SDK Command-line Tools (latest)**. Check that Android SDK Platform-Tools, Build-Tools, and the SDK platform requested by Gradle are installed. Then run:

```sh
flutter doctor --android-licenses
flutter doctor -v
flutter devices
```

Read and accept the SDK terms yourself. Resolve any remaining Android toolchain errors reported by Flutter Doctor. Android Studio's bundled JDK is the normal Gradle JDK choice; do not commit machine-specific SDK or JDK paths.

## Verification

The shared run configuration XML and its entry point have been checked. The Android debug APK build passed in this repository after resolving a Gradle download timeout. Device launch remains unverified. The initial SDK warning above is historical; run Flutter Doctor for current device/toolchain status.
