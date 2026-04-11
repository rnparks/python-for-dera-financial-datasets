"""SEC DERA Financial Statement Data Sets pipeline.

Download quarterly DERA archives, load them into a Postgres medallion
architecture (sec_raw → sec_silver → sec_gold), and expose convenience
lookups keyed by ticker or CIK.
"""

__version__ = "0.2.0"
