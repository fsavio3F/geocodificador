#!/usr/bin/env python3
"""
Script to fix height (altura) parity by swapping par/impar fields.
This corrects the bug where:
- alt_ini_pa and alt_fin_pa contain odd numbers (should be even)
- alt_ini_im and alt_fin_im contain even numbers (should be odd)

The fix swaps these fields so the parity is correct.
"""
import json
import sys
from pathlib import Path
import shutil


def fix_geojson(input_path, output_path=None, backup=True):
    """
    Fix height parity in a GeoJSON file by swapping par/impar fields.
    
    Args:
        input_path: Path to input GeoJSON file
        output_path: Path to output file (defaults to overwriting input)
        backup: If True, creates a backup of the original file
    """
    input_path = Path(input_path)
    
    if output_path is None:
        output_path = input_path
    else:
        output_path = Path(output_path)
    
    # Create backup if requested and overwriting
    if backup and input_path == output_path:
        backup_path = input_path.with_suffix('.geojson.bak')
        print(f"Creating backup: {backup_path}")
        shutil.copy2(input_path, backup_path)
    
    print(f"Loading {input_path}...")
    with open(input_path) as f:
        data = json.load(f)
    
    swapped = 0
    
    for feat in data['features']:
        props = feat['properties']
        
        # Get current values
        alt_ini_pa = props.get('alt_ini_pa')
        alt_fin_pa = props.get('alt_fin_pa')
        alt_ini_im = props.get('alt_ini_im')
        alt_fin_im = props.get('alt_fin_im')
        
        # Check if any non-null values exist
        if any(v is not None for v in [alt_ini_pa, alt_fin_pa, alt_ini_im, alt_fin_im]):
            # Swap par <-> impar
            props['alt_ini_pa'] = alt_ini_im
            props['alt_fin_pa'] = alt_fin_im
            props['alt_ini_im'] = alt_ini_pa
            props['alt_fin_im'] = alt_fin_pa
            swapped += 1
    
    print(f"Swapped height fields in {swapped} features")
    print(f"Writing to {output_path}...")
    
    with open(output_path, 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    
    print("✓ Done!")
    return swapped


def main():
    """Main entry point."""
    if len(sys.argv) > 1:
        input_path = Path(sys.argv[1])
        output_path = Path(sys.argv[2]) if len(sys.argv) > 2 else None
    else:
        # Default to the standard location
        input_path = Path(__file__).parent.parent / "data" / "callejero_geolocalizador.geojson"
        output_path = None
    
    if not input_path.exists():
        print(f"Error: File not found: {input_path}", file=sys.stderr)
        sys.exit(1)
    
    try:
        fix_geojson(input_path, output_path)
        sys.exit(0)
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
