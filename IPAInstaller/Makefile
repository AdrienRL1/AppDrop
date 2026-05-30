TARGET = iphone:clang:7.0:5.0
ARCHS = armv7
INSTALL_TARGET_PROCESSES = IPAInstaller

MBEDTLS_DIR = $(PWD)/../deps/mbedtls
MBEDTLS_LIB = $(PWD)/../deps/build

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = IPAInstaller

IPAInstaller_FILES = main.m AppDelegate.m RootViewController.m InstallManager.m CatalogViewController.m CatalogFilter.m FilterViewController.m AppDetailViewController.m IconLoader.m JobCell.m AppTileView.m AppRowCell.m VersionsViewController.m IOS6Theme.m SettingsViewController.m NetworkClient.m HTTPSClient.m LocalCatalog.m ChatMessage.m ChatViewController.m ChatBubbleView.m Localization.m PollinationsLLM.m CatalogAppCell.m SearchViewController.m MachOInspector.m ParallelDownloader.m UpdateChecker.m UpdateNotesViewController.m DeviceInfo.m IOS5Compat.m CheckpointLog.m
IPAInstaller_FRAMEWORKS = UIKit CoreGraphics Foundation QuartzCore
IPAInstaller_CFLAGS = -fobjc-arc -Wall -I$(MBEDTLS_DIR)/include
IPAInstaller_LDFLAGS = -L$(MBEDTLS_LIB) -lmbedtls -lmbedx509 -lmbedcrypto -lsqlite3 -lz
IPAInstaller_CODESIGN_FLAGS = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/application.mk

# Inject Cydia maintainer scripts (postinst/postrm) into the .deb so that
# SpringBoard re-registers /Applications/IPAInstaller.app after install
# (otherwise the icon appears square with no iOS 6 gloss).
after-stage::
	mkdir -p $(THEOS_STAGING_DIR)/DEBIAN
	cp -f Layout/DEBIAN/postinst $(THEOS_STAGING_DIR)/DEBIAN/postinst
	cp -f Layout/DEBIAN/postrm   $(THEOS_STAGING_DIR)/DEBIAN/postrm
	chmod 0755 $(THEOS_STAGING_DIR)/DEBIAN/postinst $(THEOS_STAGING_DIR)/DEBIAN/postrm
