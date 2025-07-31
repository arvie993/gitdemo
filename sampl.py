# Function to reverse a string
def reverse_string(s):
    """Returns the reversed version of the input string."""
    return s[::-1]

# Example usage
if __name__ == "__main__":
    input_string = "Hello, World!"
    reversed_string = reverse_string(input_string)
    print(f"Original: {input_string}")
    print(f"Reversed: {reversed_string}")