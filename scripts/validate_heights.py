#!/usr/bin/env python3
"""
Script to validate that height (altura) parity is correct in geocoding data.
Checks that:
- alt_ini_pa and alt_fin_pa contain even numbers
- alt_ini_im and alt_fin_im contain odd numbers
"""
import json
import sys
from pathlib import Path


def validate_geojson(filepath):
    """Validate height parity in a GeoJSON file."""
    print(f"Validating {filepath}...")
    
    with open(filepath) as f:
        data = json.load(f)
    
    issues = []
    checked = 0
    features_with_issues = set()
    
    for i, feat in enumerate(data['features']):
        props = feat['properties']
        nombre = props.get('nombre_cal', '')
        numero = props.get('numero_cal', '')
        
        alt_ini_pa = props.get('alt_ini_pa')
        alt_fin_pa = props.get('alt_fin_pa')
        alt_ini_im = props.get('alt_ini_im')
        alt_fin_im = props.get('alt_fin_im')
        
        checked += 1
        has_issue = False
        
        # Check if even heights are actually even (skip 0 as it's a special case)
        if alt_ini_pa is not None and alt_ini_pa != 0 and int(alt_ini_pa) % 2 != 0:
            issues.append({
                'index': i,
                'nombre': nombre,
                'numero': numero,
                'issue': f'alt_ini_pa should be even but is odd: {int(alt_ini_pa)}'
            })
            has_issue = True
        
        if alt_fin_pa is not None and alt_fin_pa != 0 and int(alt_fin_pa) % 2 != 0:
            issues.append({
                'index': i,
                'nombre': nombre,
                'numero': numero,
                'issue': f'alt_fin_pa should be even but is odd: {int(alt_fin_pa)}'
            })
            has_issue = True
        
        # Check if odd heights are actually odd (skip 0 as it's a special case)
        if alt_ini_im is not None and alt_ini_im != 0 and int(alt_ini_im) % 2 == 0:
            issues.append({
                'index': i,
                'nombre': nombre,
                'numero': numero,
                'issue': f'alt_ini_im should be odd but is even: {int(alt_ini_im)}'
            })
            has_issue = True
        
        if alt_fin_im is not None and alt_fin_im != 0 and int(alt_fin_im) % 2 == 0:
            issues.append({
                'index': i,
                'nombre': nombre,
                'numero': numero,
                'issue': f'alt_fin_im should be odd but is even: {int(alt_fin_im)}'
            })
            has_issue = True
        
        if has_issue:
            features_with_issues.add(i)
    
    print(f"✓ Checked {checked} features")
    print(f"✗ Found {len(issues)} parity issues")
    print(f"✗ Features affected: {len(features_with_issues)}")
    
    if issues:
        print("\nFirst 10 issues:")
        for issue in issues[:10]:
            print(f"  Feature {issue['index']}: {issue['nombre']} ({issue['numero']})")
            print(f"    → {issue['issue']}")
        
        if len(issues) > 10:
            print(f"\n  ... and {len(issues) - 10} more issues")
        
        return False
    else:
        print("✓ All heights have correct parity!")
        return True


def main():
    """Main entry point."""
    if len(sys.argv) > 1:
        filepath = Path(sys.argv[1])
    else:
        # Default to the standard location
        filepath = Path(__file__).parent.parent / "data" / "callejero_geolocalizador.geojson"
    
    if not filepath.exists():
        print(f"Error: File not found: {filepath}", file=sys.stderr)
        sys.exit(1)
    
    success = validate_geojson(filepath)
    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()
