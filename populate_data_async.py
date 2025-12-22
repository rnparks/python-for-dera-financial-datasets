# -*- coding: utf-8 -*-
"""
Async script to download SEC Financial Statement Data Sets.
Updates:
1. Downloads 2020q1 through 2025q3.
2. Uses asyncio/aiohttp for concurrency.
3. Checks if files exist to avoid re-downloading.
4. ROBUSTNESS: Retries failed downloads (IncompleteRead, disconnects) automatically.

Created on Fri Aug 12 10:19:50 2024
Updated on Dec 20 2025
"""

import aiohttp
import asyncio
import zipfile
from io import BytesIO
import os
import time

# Configuration
MAX_CONCURRENT_DOWNLOADS = 5 
MAX_RETRIES = 3
RETRY_DELAY = 2  # Seconds to wait before first retry

async def download_and_unzip(session, url, extract_to, semaphore):
    """
    Asynchronously downloads and unzips a file with Retry logic.
    """
    
    # 1. Check if file exists locally
    if os.path.exists(extract_to):
        print(f"Skipping {extract_to} - already exists.")
        return

    # 2. Acquire slot in the download queue
    async with semaphore:
        headers = {
            'User-Agent': 'Script/1.0 (Contact: your-email@example.com)',
            'Accept-Encoding': 'gzip, deflate',
            'Host': 'www.sec.gov'
        }

        # 3. Retry Loop
        for attempt in range(1, MAX_RETRIES + 1):
            try:
                print(f"Starting download: {url} (Attempt {attempt}/{MAX_RETRIES}) ...")
                
                # Set a timeout for the connection (300 seconds = 5 minutes)
                # This prevents hanging on stuck connections
                timeout = aiohttp.ClientTimeout(total=300)
                
                async with session.get(url, headers=headers, timeout=timeout) as response:
                    response.raise_for_status()
                    
                    # Read content (this is where IncompleteRead usually happens)
                    content = await response.read()

                    print(f"Extracting to {extract_to}...")
                    
                    try:
                        with zipfile.ZipFile(BytesIO(content)) as zip_ref:
                            if not os.path.exists(extract_to):
                                os.makedirs(extract_to)
                            zip_ref.extractall(path=extract_to)
                        print(f"SUCCESS: {extract_to}")
                        return  # Exit function on success
                        
                    except zipfile.BadZipFile:
                        print(f"Error: Bad Zip File for {url}")
                        return # Don't retry bad zips, they are likely corrupt on server
                        
            except (aiohttp.ClientPayloadError, aiohttp.ClientError, asyncio.TimeoutError) as e:
                print(f"Network error on {url}: {e}")
                
            except Exception as e:
                # Catch generic errors (like the one you pasted)
                print(f"Unexpected error on {url}: {e}")

            # If we are here, the download failed.
            if attempt < MAX_RETRIES:
                wait_time = RETRY_DELAY * attempt
                print(f"Retrying {url} in {wait_time} seconds...")
                await asyncio.sleep(wait_time)
            else:
                print(f"FAILED: Could not download {url} after {MAX_RETRIES} attempts.")

async def main():
    tasks = []
    semaphore = asyncio.Semaphore(MAX_CONCURRENT_DOWNLOADS)

    # Increased session timeout slightly for safety
    timeout = aiohttp.ClientTimeout(total=600)
    
    async with aiohttp.ClientSession(timeout=timeout) as session:
        for year in range(2009, 2026):
            for quarter in range(1, 5):
                
                if year == 2012 and quarter > 3:
                    break
                
                q_str = f"{year}q{quarter}"
                url = f"https://www.sec.gov/files/dera/data/financial-statement-data-sets/{q_str}.zip"
                extract_path = f"examples/data/{q_str}"
                
                task = download_and_unzip(session, url, extract_path, semaphore)
                tasks.append(task)

        start_time = time.time()
        await asyncio.gather(*tasks)
        end_time = time.time()
        
        print(f"\nOperation finished in {end_time - start_time:.2f} seconds.")

if __name__ == "__main__":
    if os.name == 'nt':
        asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())
        
    asyncio.run(main())