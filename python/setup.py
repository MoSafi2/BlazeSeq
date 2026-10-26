"""Mark the prebuilt Mojo extension as an interpreter-specific binary wheel."""

from setuptools import Distribution, setup


class BinaryDistribution(Distribution):
    def has_ext_modules(self):
        return True


setup(distclass=BinaryDistribution)
