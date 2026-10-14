# Opt-in research-primary profile. Include after the generated cubs.mk body.
# Unsupported OEM audio interfaces must not remain VINTF-declared and wait
# forever for the removed proprietary process.
PRODUCT_PACKAGES := $(filter-out \
    android.hardware.audio.service-aidl.aoc \
    adevtool_vintf_fragment_vendor_android.hardware.audio.service-aidl.aoc.xml,\
    $(PRODUCT_PACKAGES))
PRODUCT_COPY_FILES := $(filter-out \
    vendor/google_devices/cubs/proprietary/vendor/etc/init/android.hardware.audio.service-aidl.aoc.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/android.hardware.audio.service-aidl.aoc.rc,\
    $(PRODUCT_COPY_FILES))
PRODUCT_PACKAGES += \
    android.hardware.audio.service-aidl.powerphone-cubs \
    libpowerphone_tinyalsa_v1 \
    cubs_powerphone_boot \
    cubs_powerphone_services_rc \
    cubs_powerphone_platform_gate_rc \
    cubs_powerphone_manifest
# Release D5 promptly so a completed UI track does not retain a research BUS
# lease for AudioFlinger's normal three-second idle standby period.
PRODUCT_VENDOR_PROPERTIES += ro.audio.flinger_standbytime_ms=0
# Keep the auditable profile fragment in the image. Its active overrides are
# platform early-init setprop actions in the already-installed platform gate;
# simply appending vendor properties loses to the donor product/build.prop.
PRODUCT_COPY_FILES += \
    vendor/google_devices/cubs/powerphone/bluetooth-research.prop:$(TARGET_COPY_OUT_VENDOR)/etc/powerphone-cubs-bluetooth-research.prop
