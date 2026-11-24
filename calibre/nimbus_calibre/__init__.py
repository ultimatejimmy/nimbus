"""Nimbus Cloud Calibre Companion Plugin."""

try:
    from calibre.customize import InterfaceActionBase
except ImportError:  # pragma: no cover
    class InterfaceActionBase:  # type: ignore
        pass


class NimbusCalibrePlugin(InterfaceActionBase):
    name = "Nimbus Cloud"
    description = "Sync books, reading progress, and highlights with Nimbus Cloud (GDrive, OneDrive, Dropbox, WebDAV)."
    supported_platforms = ["windows", "osx", "linux"]
    author = "Nimbus"
    version = (26, 11, 24)
    minimum_calibre_version = (5, 0, 0)
    actual_plugin = "calibre_plugins.nimbus_calibre.ui:NimbusAction"

    def is_customizable(self):
        return False
