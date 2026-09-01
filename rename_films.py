import os
from pathlib import Path

# for p in Path('input_directory').iterdir():
for p in Path('.').iterdir():
    if p.is_file():
        parts = p.name.split('.')
	new_name = parts[1] + '.' + parts[-1]
#        new_name = f'{parts[2]}.{parts[-1]}'
#        print(f'{p}->{p.parent / new_name}')
        print(p.name, new_name)
#        p.rename(p.parent / new_name)
#        os.rename(p.parent, new_name)

