import os
from pathlib import Path

# for p in Path('input_directory').iterdir():
for p in Path('.').iterdir():
	number = "-1"
	print ("File is", p.parent, p.name)
   	if p.is_file():
        	parts = p.name.split('.')
		parts1 = [x.replace ('Ep-','') for x in parts]
		for part in parts1:
			if part.isdigit():
				print (part, type(part), int (part))
				number = "".join(str(x) for x in part)
				print ("Number is", number)
	if number != "-1":
		new_name = "S10E"+number+"."+parts[-1]
#        new_name = f'{parts[2]}.{parts[-1]}'
#        print(f'{p}->{p.parent / new_name}')
        	print("New name is", new_name)
#        p.rename(p.parent / new_name)
        	os.rename(p.name, new_name)

