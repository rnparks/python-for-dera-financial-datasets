"""SEC DERA Financial Statement Data Sets pipeline.

Download quarterly DERA archives, load them into a Postgres medallion
architecture (sec_raw → sec_silver → sec_gold), and expose convenience
lookups keyed by ticker or CIK.

A fourth schema, sec_reference, sits outside that chain and holds the
trading calendar, the survivorship-free company spine and the security
lifecycle model. It is deliberately outside because `build-silver` opens
with DROP SCHEMA sec_silver CASCADE and all of that must survive it.
"""

__version__ = "0.2.0"
