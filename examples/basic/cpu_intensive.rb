# CPU-intensive workload: recursive fibonacci + prime sieve
# Expected: ~3s, nearly 100% CPU time

def fib(n)
  return n if n <= 1
  fib(n - 1) + fib(n - 2)
end

def sieve(limit)
  is_prime = Array.new(limit + 1, true)
  is_prime[0] = is_prime[1] = false
  (2..Math.sqrt(limit).to_i).each do |i|
    next unless is_prime[i]
    (i * i..limit).step(i) { |j| is_prime[j] = false }
  end
  is_prime.each_index.select { |i| is_prime[i] }
end

def sort_random(n)
  ary = Array.new(n) { rand }
  ary.sort
end

# ~1.5s
puts "Computing fib(38)..."
result = fib(38)
puts "fib(38) = #{result}"

# ~1s
puts "Prime sieve up to 5,000,000..."
primes = sieve(5_000_000)
puts "Found #{primes.size} primes"

# ~0.5s
puts "Sorting 3,000,000 random numbers..."
sorted = sort_random(3_000_000)
puts "First 5: #{sorted.first(5).map { |x| x.round(4) }}"
