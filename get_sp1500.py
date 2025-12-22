import pandas as pd
import requests
from io import StringIO

# The 3 components of the S&P 1500
URLS = {
    "SP500": "https://en.wikipedia.org/wiki/List_of_S%26P_500_companies",
    "SP400": "https://en.wikipedia.org/wiki/List_of_S%26P_400_companies",
    "SP600": "https://en.wikipedia.org/wiki/List_of_S%26P_600_companies"
}

# Define a header so Wikipedia knows we are a legitimate student/researcher
HEADERS = {
    "User-Agent": "QuantResearchProject/1.0 (contact: test@example.com)"
}

all_tickers = []

print("Scraping S&P Indices...")

for index_name, url in URLS.items():
    print(f"Fetching {index_name}...")
    try:
        # 1. Fetch the raw HTML using requests (with the User-Agent)
        response = requests.get(url, headers=HEADERS)
        response.raise_for_status() # Check for errors
        
        # 2. Feed the HTML text to Pandas using StringIO
        # (Pandas expects a file-like object, not a raw string)
        dfs = pd.read_html(StringIO(response.text))
        
        # 3. Find the right table
        # The constituents table is usually the first one [0]
        df = dfs[0]
        
        # 4. Find the correct columns dynamically
        # Wiki headers change often, so we look for keywords
        ticker_col = [c for c in df.columns if "Symbol" in c or "Ticker" in c][0]
        name_col = [c for c in df.columns if "Security" in c or "Company" in c][0]
        
        # 5. Extract and Clean
        subset = df[[ticker_col, name_col]].copy()
        subset.columns = ['ticker', 'name']
        subset['index_name'] = index_name
        
        all_tickers.append(subset)
        print(f"   -> Found {len(subset)} companies.")
        
    except Exception as e:
        print(f"Error scraping {index_name}: {e}")

if all_tickers:
    # Combine all 3 lists
    full_universe = pd.concat(all_tickers)
    
    # Save to CSV
    output_file = "sp1500_universe.csv"
    full_universe.to_csv(output_file, index=False)
    print(f"\nSuccess! Saved {len(full_universe)} tickers to {output_file}")
else:
    print("\nFailed. No tickers found.")