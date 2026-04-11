import pandas as pd
from pathlib import Path

# ==================================================
# Configuration
# ==================================================
BASE_PATH = Path("examples/data/2025q3")

TAG_FILE = BASE_PATH / "tag.txt"
PRE_FILE = BASE_PATH / "pre.txt"

OUTPUT_FILE = Path("revenue_labels_new.xlsx")

REVENUE_TAG = "RevenueFromContractWithCustomerExcludingAssessedTax"

# ==================================================
# Load files
# ==================================================
tag_df = pd.read_csv(TAG_FILE, sep="\t", dtype=str)
pre_df = pd.read_csv(PRE_FILE, sep="\t", dtype=str)

# ==================================================
# FILTER pre.txt to true consolidated IS line items
# ==================================================
pre_filtered = pre_df.copy()

# Income statement only
pre_filtered = pre_filtered[pre_filtered["stmt"] == "IS"]

# No segment / dimensional breakdowns
for col in ["segment", "member"]:
    if col in pre_filtered.columns:
        pre_filtered = pre_filtered[pre_filtered[col].isna()]

# No abstract rows (headers, subtotals)
if "abstract" in pre_filtered.columns:
    pre_filtered = pre_filtered[pre_filtered["abstract"] == "false"]

# Must be an actual line item
if "line" in pre_filtered.columns:
    pre_filtered = pre_filtered[pre_filtered["line"].notna()]

# ==================================================
# Merge AFTER filtering
# ==================================================
merged_df = tag_df.merge(
    pre_filtered,
    on="tag",
    how="inner"   # inner is correct now
)

# ==================================================
# Extract labels for the revenue tag
# ==================================================
revenue_labels_df = (
    merged_df.loc[
        merged_df["tag"] == REVENUE_TAG,
        ["tag", "tlabel", "plabel"]
    ]
    .drop_duplicates()
    .sort_values("plabel")
)

# ==================================================
# Save to Excel
# ==================================================
revenue_labels_df.to_excel(
    OUTPUT_FILE,
    index=False,
    sheet_name="Revenue Labels"
)

print(f"Saved consolidated revenue labels to: {OUTPUT_FILE.resolve()}")
print(f"Total labels (consolidated IS only): {len(revenue_labels_df)}")
