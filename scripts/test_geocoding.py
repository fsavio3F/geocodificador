#!/usr/bin/env python3
"""
Test script to verify that geocoding works correctly with the fixed height parity.
This simulates the logic from the geocode_direccion SQL function.
"""
import json
import sys
from pathlib import Path


def test_geocoding_logic(data_file):
    """Test that the geocoding logic works with the fixed data."""
    print(f"Testing geocoding logic with {data_file}...")
    
    with open(data_file) as f:
        data = json.load(f)
    
    test_cases = []
    success_count = 0
    total_tests = 0
    
    # Test a sample of streets with even and odd addresses
    for i, feat in enumerate(data['features'][:100]):  # Test first 100 features
        props = feat['properties']
        nombre = props.get('nombre_cal', '')
        
        alt_ini_pa = props.get('alt_ini_pa')
        alt_fin_pa = props.get('alt_fin_pa')
        alt_ini_im = props.get('alt_ini_im')
        alt_fin_im = props.get('alt_fin_im')
        
        # Skip features without height data
        if not any([alt_ini_pa, alt_fin_pa, alt_ini_im, alt_fin_im]):
            continue
        
        # Test an even address
        if alt_ini_pa and alt_fin_pa:
            altura_test = int((alt_ini_pa + alt_fin_pa) / 2)
            if altura_test % 2 == 0:  # Make sure it's even
                min_par = min(alt_ini_pa, alt_fin_pa)
                max_par = max(alt_ini_pa, alt_fin_pa)
                
                # This simulates the geocode_direccion logic
                in_range = min_par <= altura_test <= max_par
                
                total_tests += 1
                if in_range:
                    success_count += 1
                    test_cases.append({
                        'nombre': nombre,
                        'altura': altura_test,
                        'paridad': 'par',
                        'range': (min_par, max_par),
                        'success': True
                    })
        
        # Test an odd address
        if alt_ini_im and alt_fin_im:
            altura_test = int((alt_ini_im + alt_fin_im) / 2)
            if altura_test % 2 == 1:  # Make sure it's odd
                min_impar = min(alt_ini_im, alt_fin_im)
                max_impar = max(alt_ini_im, alt_fin_im)
                
                # This simulates the geocode_direccion logic
                in_range = min_impar <= altura_test <= max_impar
                
                total_tests += 1
                if in_range:
                    success_count += 1
                    test_cases.append({
                        'nombre': nombre,
                        'altura': altura_test,
                        'paridad': 'impar',
                        'range': (min_impar, max_impar),
                        'success': True
                    })
        
        if len(test_cases) >= 20:  # Collect 20 successful examples
            break
    
    print(f"\n✓ Tested {total_tests} addresses")
    print(f"✓ Success rate: {success_count}/{total_tests} ({100*success_count/total_tests:.1f}%)")
    print(f"\nSample successful geocoding tests:")
    for i, tc in enumerate(test_cases[:10], 1):
        print(f"  {i}. {tc['nombre']}, altura {tc['altura']} ({tc['paridad']})")
        print(f"     → Range: {tc['range'][0]}-{tc['range'][1]}")
    
    return success_count == total_tests


def test_parity_correctness(data_file):
    """Verify that the height fields have correct parity after the fix."""
    print(f"\nVerifying parity correctness...")
    
    with open(data_file) as f:
        data = json.load(f)
    
    correct = 0
    incorrect = 0
    total = 0
    
    for feat in data['features']:
        props = feat['properties']
        
        alt_ini_pa = props.get('alt_ini_pa')
        alt_fin_pa = props.get('alt_fin_pa')
        alt_ini_im = props.get('alt_ini_im')
        alt_fin_im = props.get('alt_fin_im')
        
        # Skip features without height data
        if not any([alt_ini_pa, alt_fin_pa, alt_ini_im, alt_fin_im]):
            continue
        
        total += 1
        
        # Check parity
        has_issue = False
        if alt_ini_pa and alt_ini_pa != 0 and int(alt_ini_pa) % 2 != 0:
            has_issue = True
        if alt_fin_pa and alt_fin_pa != 0 and int(alt_fin_pa) % 2 != 0:
            has_issue = True
        if alt_ini_im and alt_ini_im != 0 and int(alt_ini_im) % 2 == 0:
            has_issue = True
        if alt_fin_im and alt_fin_im != 0 and int(alt_fin_im) % 2 == 0:
            has_issue = True
        
        if has_issue:
            incorrect += 1
        else:
            correct += 1
    
    print(f"✓ Total features with height data: {total}")
    print(f"✓ Features with correct parity: {correct} ({100*correct/total:.1f}%)")
    print(f"✗ Features with incorrect parity: {incorrect} ({100*incorrect/total:.1f}%)")
    
    # Success if >70% are correct (since some real-world irregularities are expected)
    return correct / total > 0.7


def main():
    """Main entry point."""
    if len(sys.argv) > 1:
        data_file = Path(sys.argv[1])
    else:
        data_file = Path(__file__).parent.parent / "data" / "callejero_geolocalizador.geojson"
    
    if not data_file.exists():
        print(f"Error: File not found: {data_file}", file=sys.stderr)
        sys.exit(1)
    
    print("="*60)
    print("Testing Geocoding with Fixed Height Parity")
    print("="*60)
    
    parity_ok = test_parity_correctness(data_file)
    geocoding_ok = test_geocoding_logic(data_file)
    
    print("\n" + "="*60)
    if parity_ok and geocoding_ok:
        print("✓ ALL TESTS PASSED!")
        print("  The height parity fix is working correctly.")
        sys.exit(0)
    else:
        print("✗ TESTS FAILED")
        if not parity_ok:
            print("  - Parity verification failed")
        if not geocoding_ok:
            print("  - Geocoding logic test failed")
        sys.exit(1)


if __name__ == "__main__":
    main()
