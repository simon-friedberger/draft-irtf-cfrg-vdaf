# Pseudorandom number generators (PRGs).

from __future__ import annotations
from Cryptodome.Cipher import AES
from Cryptodome.Hash import CMAC, cSHAKE128
from Cryptodome.Util import Counter
from Cryptodome.Util.number import bytes_to_long
from sagelib.common import TEST_VECTOR, VERSION, Bytes, Error, Unsigned, \
                           format_custom, zeros, from_le_bytes, gen_rand, \
                           next_power_of_2, print_wrapped_line, to_be_bytes, \
                           to_le_bytes

# The base class for PRGs.
class Prg:
    # Size of the seed.
    SEED_SIZE: Unsigned

    # Construct a new instnace of this PRG from the given seed and info string.
    def __init__(self, seed: Bytes[Prg.SEED_SIZE], custom: Bytes, binder: Bytes):
        raise Error('not implemented')

    # Output the next `length` bytes of the PRG stream.
    def next(self, length: Unsigned) -> Bytes:
        raise Error('not implemented')

    # Derive a new seed.
    @classmethod
    def derive_seed(Prg, seed: Bytes[Prg.SEED_SIZE], custom: Bytes, binder: Bytes):
        prg = Prg(seed, custom, binder)
        return prg.next(Prg.SEED_SIZE)

    # Output the next `length` pseudorandom elements of `Field`.
    def next_vec(self, Field, length: Unsigned):
        m = next_power_of_2(Field.MODULUS) - 1
        vec = []
        while len(vec) < length:
            x = from_le_bytes(self.next(Field.ENCODED_SIZE))
            x &= m
            if x < Field.MODULUS:
                vec.append(Field(x))
        return vec

    # Expand the input `seed` into vector of `length` field elements.
    @classmethod
    def expand_into_vec(Prg,
                        Field,
                        seed: Bytes[Prg.SEED_SIZE],
                        custom: Bytes,
                        binder: Bytes,
                        length: Unsigned):
        prg = Prg(seed, custom, binder)
        return prg.next_vec(Field, length)

# WARNING `PrgAes128` has been deprecated in favor of `PrgSha3`.
class PrgAes128(Prg):
    # Associated parameters
    SEED_SIZE = 16

    def __init__(self, seed, custom, binder):
        self.length_consumed = 0

        # Use CMAC as a pseuodorandom function to derive a key.
        hasher = CMAC.new(seed, ciphermod=AES)
        hasher.update(to_be_bytes(len(custom), 2))
        hasher.update(custom)
        hasher.update(binder)
        self.key = hasher.digest()

    def next(self, length: Unsigned) -> Bytes:
        block = int(self.length_consumed / 16)
        offset = self.length_consumed % 16
        self.length_consumed += length

        # CTR-mode encryption of the all-zero string of the desired
        # length and using a fixed, all-zero IV.
        counter = Counter.new(int(128), initial_value=block)
        cipher = AES.new(self.key, AES.MODE_CTR, counter=counter)
        stream = cipher.encrypt(zeros(offset + length))
        return stream[-length:]

# PRG based on SHA-3 (cSHAKE128).
class PrgSha3(Prg):
    # Associated parameters
    SEED_SIZE = 16

    def __init__(self, seed, custom, binder):
        # `custom` is used as the customization string; `seed || binder` is
        # used as the main input string.
        self.shake = cSHAKE128.new(custom=custom)
        self.shake.update(seed)
        self.shake.update(binder)

    def next(self, length: Unsigned) -> Bytes:
        return self.shake.read(length)

##
# TESTS
#

def test_prg(Prg, F, expanded_len):
    custom = format_custom(7, 1337, 2)
    binder = b'a string that binds some protocol artifact to the output'
    seed = gen_rand(Prg.SEED_SIZE)

    # Test next
    expanded_data = Prg(seed, custom, binder).next(expanded_len)
    assert len(expanded_data) == expanded_len

    want = Prg(seed, custom, binder).next(700)
    got = b''
    prg = Prg(seed, custom, binder)
    for i in range(0, 700, 7):
        got += prg.next(7)
    assert got == want

    # Test derive
    derived_seed = Prg.derive_seed(seed, custom, binder)
    assert len(derived_seed) == Prg.SEED_SIZE

    # Test expand_into_vec
    expanded_vec = Prg.expand_into_vec(F, seed, custom, binder, expanded_len)
    assert len(expanded_vec) == expanded_len


# Find seeds for `Prg` for which, when expanded into a vector of `Field`
# elements, an output larger than the field modulus is generated. The output is
# used to write tests for proper rejection sampling in `Prg` implementations.
def probe_for_rejection(Prg, Field, start_seed_int=0):
    custom = b''
    binder = b''
    mask = next_power_of_2(Field.MODULUS) - 1
    for seed_int in range(start_seed_int, start_seed_int+1_000_000):
        seed = to_le_bytes(seed_int, Prg.SEED_SIZE)
        prg = Prg(seed, custom, binder)
        for offset in range(1024):
            value = from_le_bytes(prg.next(Field.ENCODED_SIZE))
            value &= mask
            if value >= Field.MODULUS:
                print('Rejection! field = {} seed = {}, offset = {}, next_value = {}'
                      .format(Field.__name__, seed, offset, prg.next_vec(Field, 1)))

if __name__ == '__main__':
    import json
    from sagelib.field import Field128, Field64, Field96

    # Parameters match output of: probe_for_rejection(PrgSha3, Field96)
    expanded_vec = PrgSha3.expand_into_vec(
        Field96,
        b'@\x02\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00',
        b'', # custom
        b'', # binder
        328,
    )
    assert expanded_vec[-1] == Field96(55625305487129755078517911529)

    for cls in (PrgAes128, PrgSha3):
        test_prg(cls, Field128, 23)

        if TEST_VECTOR:
            seed = gen_rand(cls.SEED_SIZE)
            custom = b'custom string'
            binder = b'binder string'
            length = 40

            test_vector = {
                'seed': seed.hex(),
                'custom': custom.hex(),
                'binder': binder.hex(),
                'length': int(length),
                'derived_seed': None, # set below
                'expanded_vec_field128': None, # set below
            }

            test_vector['derived_seed'] = cls.derive_seed(seed, custom, binder).hex()
            test_vector['expanded_vec_field128'] = Field128.encode_vec(
                    cls.expand_into_vec(Field128, seed, custom, binder, length)).hex()

            print('{}:'.format(cls.__name__))
            print('  seed: "{}"'.format(test_vector['seed']))
            print('  custom: "{}"'.format(test_vector['custom']))
            print('  binder: "{}"'.format(test_vector['binder']))
            print('  length: {}'.format(test_vector['length']))
            print('  derived_seed: "{}"'.format(test_vector['derived_seed']))
            print('  expanded_vec_field128: >-')
            print_wrapped_line(test_vector['expanded_vec_field128'], tab=4)

            os.system('mkdir -p test_vec/{:02}'.format(VERSION))
            with open('test_vec/{:02}/{}.json'.format(VERSION, cls.__name__), 'w') as f:
                json.dump(test_vector, f, indent=4, sort_keys=True)
                f.write('\n')
