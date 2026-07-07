#!/usr/bin/env python3
import argparse
import sys

def main():
    parser = argparse.ArgumentParser(description="Rebuild expected board state from journal and diff against actual.")
    # Add arguments here in the future
    args = parser.parse_args()
    print("idc_journal_replay.py: Not yet implemented.", file=sys.stderr)
    sys.exit(0)

if __name__ == "__main__":
    main()
