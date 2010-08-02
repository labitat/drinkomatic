#!/usr/bin/env python
import sys, sqlite3, serial, hashlib, thread, time, tty, termios, threading, re

db = '/opt/drinkomatic/micropay.db'

conn = sqlite3.connect(db)
cursor = conn.cursor()
conn.isolation_level = None

card_reader = serial.Serial("/dev/ttyS0", baudrate=9600)
barcode_reader = serial.Serial("/dev/ttyUSB0", baudrate=9600)

lastaction = time.time()

card_cond = threading.Condition() # condition for card hash and related variables below
card_hash = ""
last_active_time = 0
adding_new_customer = False
new_customer_hash = ""
card_enabled = True

barcode_cond = threading.Condition() # condition for barcode and related variables below
adding_new_product = False
new_product_barcode = ""
barcode_enabled = True


def read_card():
    h = hashlib.sha1()
    card = card_reader.readline(eol=chr(13))
    h.update(card)
    card = h.hexdigest().upper()
    return card

def read_barcode():
    code = barcode_reader.readline(eol=chr(13))
    code = re.sub("[^\d]+",'', code)
    return code

class LoginTimeoutThread(threading.Thread):
  
  def run(self):
    global card_cond
    global last_active_time

    while True:
      time.sleep(1)
      card_cond.acquire()
      last_time = last_active_time
      card_cond.release()

      if (time.time() - last_time) > 30:
        logout("Logged out due to inactivity...")


def logout(msg):
  global card_cond
  global card_hash
  global card_enabled

  card_cond.acquire()
  if card_enabled == False:
    card_cond.release()
    return

  if card_hash != "":
    card_hash = ""

    print "\r\n" * 40
    print "%s\r" % msg

  card_cond.release()



class CardThread(threading.Thread):

  def run(self):
    global card_hash
    global adding_new_customer
    global new_customer_hash
    global card_cond
    global card_enabled
    global db

    con = sqlite3.connect(db)
    self.cur = con.cursor()
    con.isolation_level = None

    while True:
      h = read_card()
      card_cond.acquire()
      if card_enabled == False:
        card_cond.notify()
        card_cond.release()
        continue

      if adding_new_customer == True:
        new_customer_hash = h
      else:
        card_hash = h
        self.login()

      card_cond.notify()
      card_cond.release()


  def login(self):
    global card_cond
    global last_active_time

    t = (card_hash,)
    self.cur.execute('select balance, member from accounts where hash = ?', t)
    r = self.cur.fetchone()

    if r != None:
      print "-------------------------------\r"
      print "Logged in as: %s\r" % r[1]
      print "With account balance: %.2f\r" % r[0]
      print "-------------------------------\r"
      print "Scan barcode: \r"

      last_active_time = time.time()
    else:
      print "Unknown customer\r"



class BarcodeThread(threading.Thread):

  def run(self):
    global card_cond
    global db
    global barcode_cond
    global adding_new_product
    global new_product_barcode
    global barcode_enabled

    con = sqlite3.connect(db)
    self.cur = con.cursor()
    con.isolation_level = None

    while True:
      barcode = read_barcode()
      barcode_cond.acquire()
      if barcode_enabled == False:
        barcode_cond.notify()
        barcode_cond.release()
        continue
 
      if adding_new_product == True:
        new_product_barcode = barcode
        barcode_cond.notify()
        barcode_cond.release()
      else:
        barcode_cond.notify()
        barcode_cond.release()
        self.buy(barcode)
      
      
  def buy(self, barcode):
    global card_cond

    t = (barcode,)
    self.cur.execute('select price, name from products where barcode = ?', t)
    r = self.cur.fetchone()

    card_cond.acquire()
    h = card_hash
    last_active_time = time.time()
    card_cond.release()

    print "------------------\r"

    if h == "":
      print "Price check!\r"
    else:
      print "Buying product!\r"

    if r == None:
      print "Unknown product!\r"
      print "------------------\r"
    else:
      price = r[0]
      product = r[1]
      print "Product: %s\r" % product
      print "Price  : %.2f\r" % price


    if h != "":
      t = (price, h)
      self.cur.execute('update accounts set balance = balance - ? where hash = ?', t)
      t = (h,)
      self.cur.execute('select balance from accounts where hash = ?', t)
      r = self.cur.fetchone()

      print "Balance after purchase: %.2f\r" % r[0]
      print "\r"
      print "=== REMEMBER TO LOG OUT ===\r"
      print "------------------\r"


def add_money():
  global card_cond

  disable_card()
  disable_barcode()

  card_cond.acquire()
  h = card_hash
  card_cond.release()

  if h == "":
    print "Not logged in... Swipe card and try again.\r"
    enable_card()
    enable_barcode()
    return
  else:
    t = (h,)
    cursor.execute('select balance from accounts where hash = ?', t)
    r = cursor.fetchone()

    print "Adding money to account (enter to abort)\r"
    print "\r"
    print "Current balance: %.2f\r" % r[0]
    str = raw_input2("Enter amount: ")
    str = re.sub("[^\d]",'', str)

    if str == "":
      print "Aborted\r"
      enable_card()
      enable_barcode()
      return

    print "got here\r"

    amount = int(str)

    t = (amount, h)
    cursor.execute('update accounts set balance = balance + ? where hash = ?', t)
    t = (h,)
    cursor.execute('select balance from accounts where hash = ?', t)
    r = cursor.fetchone()
    print "Updated balance: %.2f" % r[0]

    enable_barcode()
    enable_card()

def new_customer():
  global card_cond
  global card_enabled
  global adding_new_customer
  global new_customer_hash

  disable_barcode()
  disable_card()

  print "New costumer\r"
  print "\r"
  name = raw_input2("Enter member name (enter to abort):")
  if name == "":
    print "Aborted!\r"
    enable_card()
    enable_barcode()
    return
  
  card_cond.acquire()
  print "Swipe card\r"
  adding_new_customer = True
  card_enabled = True
  card_cond.wait()
  adding_new_customer = False
  card_enabled = False
  h = new_customer_hash
  card_cond.release()

  if h == "":
    print "Card read error!\r"
    enable_card()
    enable_barcode()
    return
    
  print "Card read OK!\r"
  str = raw_input2("Enter initial deposit (enter to abort): ")
  str = re.sub("[^\d]",'', str)

  if str == "":
    print "Aborted!\r"
    enable_card()
    enable_barcode()
    return
  
  amount = int(str)

  print "Amount parsed as DKK %d\r" % amount
  t = (h,name,amount)
  try:
    cursor.execute('insert into accounts (hash,member,balance) values (?,?,?)', t)
  except sqlite3.IntegrityError:
    print "ERROR: Card already exists in database\r"
    enable_card()
    enable_barcode()
    return
  except ValueError:
    print "ERROR: Invalid value\r"
    enable_card()
    enable_barcode()
    return

  print "Account #%d created\r" % cursor.lastrowid
  print "\r"
  print "Swipe card again to log in.\r"

  enable_barcode()
  enable_card()

def raw_input2(str):
  sys.stdout.write(str)
  line = sys.stdin.readline()
  line = re.sub("[\r\n]+",'', line)
#  line = re.sub("[\x00-\x1f]+", '', line)
  return line


def new_product():
  global barcode_cond
  global adding_new_product
  global new_product_barcode
  global barcode_enabled

  disable_card()
  disable_barcode()

  print "New product\r"
  print "\r"
  print "Enter product name (enter to abort)"
  name = raw_input2("name: ")
  if name == "":
    print "Aborted!\r"
    enable_card()
    enable_barcode()
    return

  print "Scan barcode\r"
  barcode_cond.acquire()
  barcode_enabled = True
  adding_new_product = True
  barcode_cond.wait()
  adding_new_product = False
  barcode_enabled = False
  barcode = new_product_barcode
  barcode_cond.release()


  if barcode == "":
    print "Barcode read error!\r"
    enable_card()
    enable_barcode()
    return
    
  print "Barcode read OK: %s\r" % barcode
  print "Enter price (enter to abort)\r"
  str = raw_input2("price: ")
  str = re.sub("[^\d]",'', str)

  if str == "":
    print "Aborted!\r"
    enable_card()
    enable_barcode()
    return
  
  amount = int(str)

  print "Price parsed as DKK %d\r" % amount

  try:
    t = (name, amount, barcode)
    cursor.execute('insert into products (name,price,barcode) values (?,?,?)', t)
  except sqlite3.IntegrityError:
    print "ERROR: Product already exists in database\r"
    enable_card()
    enable_barcode()
    return
  except ValueError:
    print "ERROR: Invalid value\r"
    enable_card()
    enable_barcode()
    return

  print "Product #%d created\r" % cursor.lastrowid

  enable_barcode()
  enable_card()

def update_product():
  global barcode_cond
  global barcode_enabled
  global adding_new_product
  global new_product_barcode

  disable_card()
  disable_barcode()

  print "Update product\r"
  print "\r"

  print "Scan barcode\r"

  barcode_cond.acquire()
  barcode_enabled = True
  adding_new_product = True
  barcode_cond.wait()
  adding_new_product = False
  barcode_enabled = False
  barcode = new_product_barcode
  barcode_cond.release()
  
  if barcode == "":
    print "Barcode read error!\r"
    enable_card()
    enable_barcode()
    return

  print "Barcode read OK: %s\r" % barcode

  t = (barcode,)
  cursor.execute('select name, price from products where barcode = ?', t)
  r = cursor.fetchone()
  if r == None:
    print "Unknown product!\r"
    enable_card()
    enable_barcode()
    return

  print "Product: %s\r" % r[0]
  print "Price: %s\r" % r[1]
  print "\r"

  print "Enter new product name\r"
  print "(just press enter to keep existing name)\r"
  name = raw_input2("name: ")
  if name == "-":
    print "Aborted!\r"
    enable_card()
    enable_barcode()
    return
  elif name == "":
    name = r[0]

  print "Enter new product price\r"
  print "(just press enter to keep existing price)\r"  
  str = raw_input2("price: ")
  str = re.sub("[^\d]",'', str)

  if str == "-":
    print "Aborted!\r"
    enable_card()
    enable_barcode()
    return
  elif str == "":
    str = r[1]
  
  amount = int(str)

  print "Price parsed as DKK %d\r" % amount
    
  try:
    t = (name, amount,barcode)
    cursor.execute('update products set name = ?, price = ? where barcode = ?', t)
  except sqlite3.IntegrityError:
    print "ERROR: Product already exists in database\r"
    enable_card()
    enable_barcode()
    return
  except ValueError:
    print "ERROR: Invalid value\r"
    enable_card()
    enable_barcode()
    return

  print "Product updated!\r"

  enable_card()
  enable_barcode()


def getch():
  fd = sys.stdin.fileno()
  old_settings = termios.tcgetattr(fd)
  try:
    tty.setraw(sys.stdin.fileno())
    ch = sys.stdin.read(1)
  finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, old_settings)
    return ch


def disable_card():
    global card_cond
    global card_enabled

    card_cond.acquire()
    card_enabled = False
    card_cond.release()

def enable_card():
    global card_cond
    global card_enabled

    card_cond.acquire()
    card_enabled = True
    card_cond.release()

def disable_barcode():
    global barcode_cond
    global barcode_enabled

    barcode_cond.acquire()
    barcode_enabled = False
    barcode_cond.release()

def enable_barcode():
    global barcode_cond
    global barcode_enabled

    barcode_cond.acquire()
    barcode_enabled = True
    barcode_cond.release()

def menu():

  print "-----------------------------------------\r"
  print "    Swipe card at any time to log in,\r"
  print "    scan barcode(s) and hit \"-\" or\r"
  print "    wait 30 seconds to log out\r"
  print "\r"
  print "* | Print this menu\r"
  print "- | Log out / Escape\r"
  print "/ | Add money to card\r"
  print "0 | New costumer\r"
  print "1 | New product\r"
  print "2 | Update product\r"
  print "-----------------------------------------\r"


def main2():
  cmd = getch()

  card_cond.acquire()
  last_active_time = time.time()
  card_cond.release()
  
  if cmd == "\r":
#    exit()
    print "ENTAR!\r"
  elif cmd == "*": # help menu
    menu()
  elif cmd == "/": # add money to card
    add_money()
  elif cmd == "0": # new customer
    new_customer()
  elif cmd == "1": # new product
    new_product()
  elif cmd == "2": # update product
    update_product()
  elif cmd == "-":
    logout("Logged out...")

  else:
    print cmd  


CardThread().start()
BarcodeThread().start()
LoginTimeoutThread().start()

while(True):
  try:    
    main2()
  except EOFError:
    print "There is no escape!"
  except KeyboardInterrupt:
    print "There is no escape!"
