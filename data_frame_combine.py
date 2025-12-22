import pandas as pd
# 1. Show more rows/cols
pd.set_option('display.max_rows', 100)
pd.set_option('display.max_columns', 50)
pd.set_option('display.width', 1000)

# 2. Fix the numbers (No scientific notation, add commas)
pd.set_option('display.float_format', '{:,.2f}'.format)
from pathlib import Path

# --- 1. SMART PATH SETUP ---

# Get the directory where this script is located
# (If running in Jupyter, use Path.cwd() instead)
root_dir = Path(__file__).resolve().parent

# Build the path to the data folder
data_dir = root_dir / "examples" / "data" / "2025Q3"

print(f"Script location: {root_dir}")
print(f"Data location:   {data_dir}")

# Define the file paths
files = {
    'sub': data_dir / 'sub.txt',
    'num': data_dir / 'num.txt',
    'tag': data_dir / 'tag.txt',
    'pre': data_dir / 'pre.txt'
}

# Quick check to ensure files exist before trying to load them
if not files['sub'].exists():
    raise FileNotFoundError(f"Could not find the data! Checked path: {files['sub']}")

# --- 2. LOAD AND MERGE (Same logic as before) ---

# Load SUB
sub = pd.read_csv(files['sub'], sep='\t', encoding='latin1')

# Filter for Apple (Example CIK: 320193)
target_ciks = [320193]
sub_filtered = sub[sub['cik'].isin(target_ciks)].copy()

# Load NUM
num = pd.read_csv(files['num'], sep='\t', encoding='latin1')

# Merge SUB + NUM
df = pd.merge(sub_filtered, num, on='adsh', how='inner')

# Load and Merge TAG
tag = pd.read_csv(files['tag'], sep='\t', encoding='latin1')
df = pd.merge(df, tag, on=['tag', 'version'], how='left')

# Load and Merge PRE
pre = pd.read_csv(files['pre'], sep='\t', encoding='latin1')
df = pd.merge(df, pre, on=['adsh', 'tag', 'version'], how='left')

# Select final columns
final_df = df[[
    'name', 'cik', 'period', 'form', 'stmt', 'report', 'line',
    'tag', 'tlabel', 'plabel', 'segments', 'value', 'inpth', 'uom', 'ddate', 'qtrs'
]].sort_values(by=['name', 'period', 'stmt', 'line'])

final_df = df[["name", 'cik', 'period', 'form', 'stmt', 'report', 'line', 'plabel', 'segments', 'value', 'inpth', 'uom', 'ddate', 'qtrs']].sort_values(by=['plabel'])

#print(final_df.head(500))
#final_df = final_df[final_df['stmt'] == 'IS'].sort_values(by=['line'])

#final_df = final_df[(final_df['stmt'] == 'IS') & (final_df['segments'].isna())]

for col in df.columns:
    print(col)
#print(final_df.head(100))







# for index, row in final_df.head(50).iterrows():
#     # 1. Create the indentation string (2 spaces per depth level)
#     # We use .get('inpth', 0) to default to 0 if the column is missing
#     indent_spaces = "  " * int(row.get('inpth', 0))
    
#     # 2. Combine indentation with the label
#     # We cut the label at 50 chars so it fits
#     label = f"{indent_spaces}{str(row['plabel'])}"
    
#     # 3. Print nicely
#     print(f"{label[:50]:<50} | {row['value']:>18,.0f}")