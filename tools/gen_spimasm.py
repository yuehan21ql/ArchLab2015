final = open("spim.S",'w')
print >>final,'.text'

with open("./tmp_disassembly.S") as f:
    for line in f:
        line2 = line.lstrip('\t')
        line2 = line2.lstrip(' ')
        if len(line2) == 0:
            continue
        elif(line2[0] == '.' or line2[0] == '#'):
            continue
        else:
            print >>final, line,
