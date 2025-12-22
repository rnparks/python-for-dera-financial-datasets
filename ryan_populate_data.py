# -*- coding: utf-8 -*-
"""
This script downloads the Financial Statement Data Sets for 2020q1 through 2025q3.

Created on Fri Aug 12 10:19:50 2024
Updated on Dec 20 2025

@author: U.S. Securities and Exchange Commission.
"""

import requests
import zipfile
from io import BytesIO
import time
import os

def download_and_unzip(url, extract_to='.'):
    """
    Downloads a ZIP file from a URL and extracts its contents
    
    Parameters
    ----------
    url : str
        URL pointing to the ZIP file.
    extract_to : str, optional
        Directory path where the contents will be extracted. The default is 'data'.

    Returns
    -------
    None.
    """
    # Define headers with a User-Agent
    # IMPORTANT: The SEC requires a valid User-Agent with an email address.
    # Please replace 'your-email@example.com' with your actual email address.
    headers = {
        'User-Agent': 'Script/1.0 (Contact: your-email@example.com)',
        'Accept-Encoding': 'gzip, deflate',
        'Host': 'www.sec.gov'
    }
    
    try:
        # Send a GET request to the URL
        print(f"Downloading ZIP file from {url} ...")
        response = requests.get(url, headers=headers)
        
        # Raise an exception if the download fails
        response.raise_for_status()
        
        # Create a ZipFile object from the bytes of the ZIP file
        zip_file = zipfile.ZipFile(BytesIO(response.content))
        
        # Create directory if it doesn't exist
        if not os.path.exists(extract_to):
            os.makedirs(extract_to)

        # Extract the contents of the Zip file
        print(f"Extracting the contents to {extract_to}...")
        zip_file.extractall(path=extract_to)
        zip_file.close()
        print("Extraction complete.")
        
    except requests.exceptions.HTTPError as e:
        print(f"HTTP Error: {e} - File may not exist yet.")
    except Exception as e:
        print(f"An error occurred: {e}")

# --- Main Execution Loop ---

# Iterate through years 2020 to 2025
for year in range(2020, 2026):
    for quarter in range(1, 5):
        
        # STOP CONDITION: If we are past 2025q3, stop the loop.
        if year == 2025 and quarter > 3:
            break
            
        # Format the quarter string (e.g., "2022q1")
        q_str = f"{year}q{quarter}"
        
        # Construct the URL
        # Note: This targets the standard Financial Statement Data Sets.
        target_url = f"https://www.sec.gov/files/dera/data/financial-statement-data-sets/{q_str}.zip"
        
        # Construct the extract path
        target_path = f"examples/data/{q_str}"
        
        # Run the download
        download_and_unzip(target_url, extract_to=target_path)
        
        # Sleep for 0.2 seconds to respect SEC rate limits (Max 10 req/sec)
        time.sleep(0.2)